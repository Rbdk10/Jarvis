-- ============================================================
-- Jarvis brain: memory + routing schema  (Supabase / Postgres)
-- ------------------------------------------------------------
-- Powers the "warm fast lane": a grounded, fast Haiku brain that reads a
-- cached digest + relevant memories, answers instantly, and writes back what
-- it learns — with a routing log so the dispatcher can be tuned over time.
--
-- Run this in the Supabase SQL editor. Read the two ⚠️ DECISIONS first.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Extensions
-- ------------------------------------------------------------
create extension if not exists vector;   -- pgvector: semantic memory retrieval

-- ⚠️ DECISION 1 — EMBEDDING DIMENSION (decide before you run this).
--    The vector(N) size MUST equal your embedding model's output size.
--    Anthropic has no embeddings API; common choices:
--      Voyage voyage-3        = 1024   (Anthropic's recommended partner)
--      Voyage voyage-3-lite   = 512
--      OpenAI text-embedding-3-small = 1536
--    This file uses 1024. If you pick another model, change EVERY vector(1024).
--    (Changing it later means an ALTER + re-embedding, so choose now.)

-- ------------------------------------------------------------
-- 1. STATE — the cached "digest": slow-changing facts about your world.
--    The app concatenates the include_in_digest rows into the fast brain's
--    CACHED system block (crosses Haiku's 4096-token cache floor → cheap +
--    low-latency). The agent on Slim keeps these rows fresh on a schedule.
-- ------------------------------------------------------------
create table if not exists state (
  slug              text primary key,            -- 'cromito', 'preferences', 'current_focus'
  title             text not null,
  body              text not null,               -- the actual text loaded into context
  include_in_digest boolean not null default true,
  sort_order        int not null default 100,    -- lower = earlier in the digest
  updated_at        timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. MEMORIES — discrete facts Jarvis learns ("remember X").
--    Written at runtime; retrieved by semantic similarity or by subject.
-- ------------------------------------------------------------
create table if not exists memories (
  id           uuid primary key default gen_random_uuid(),
  content      text not null,
  kind         text not null default 'fact',     -- fact | preference | task | person | event
  subject      text,                              -- optional tag, e.g. a project slug
  importance   int  not null default 3,           -- 1..5, bias what gets surfaced
  source       text not null default 'jarvis',    -- jarvis | agent | user
  embedding    vector(1024),                      -- nullable until embedded
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at   timestamptz                        -- null = permanent
);

create index if not exists memories_subject_idx on memories (subject);
create index if not exists memories_kind_idx    on memories (kind);
-- Fast approximate-nearest-neighbour search (cosine). Fine to create now;
-- it just gets more useful as rows accumulate.
create index if not exists memories_embedding_idx
  on memories using hnsw (embedding vector_cosine_ops);

-- ------------------------------------------------------------
-- 3. CONVERSATIONS + MESSAGES — episodic memory (survives app restarts and
--    spans devices) AND the routing log used to tune the dispatcher.
-- ------------------------------------------------------------
create table if not exists conversations (
  id         uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  device     text,
  summary    text
);

create table if not exists messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid references conversations(id) on delete cascade,
  role            text not null,                  -- user | jarvis
  content         text not null,
  -- routing / telemetry (null on user turns)
  tier            text,                           -- local | fast | specialist | agent
  model           text,                           -- e.g. claude-haiku-4-5
  specialist      text,                           -- e.g. evie (Tier 2 route)
  route_reason    text,                           -- why the router chose this path
  escalated       boolean not null default false, -- fast brain punted upward
  latency_ms      int,                            -- end-of-speech -> first audio
  created_at      timestamptz not null default now()
);

create index if not exists messages_convo_idx on messages (conversation_id, created_at);
create index if not exists messages_tier_idx   on messages (tier);

-- ------------------------------------------------------------
-- 4. match_memories() — semantic retrieval RPC for the fast lane.
--    The app embeds the utterance, calls this, and appends the hits AFTER the
--    cached digest block (so the cache prefix stays byte-stable).
-- ------------------------------------------------------------
create or replace function match_memories(
  query_embedding vector(1024),
  match_count     int   default 6,
  min_similarity  float default 0.3,
  filter_subject  text  default null
)
returns table (id uuid, content text, kind text, subject text, similarity float)
language sql stable
as $$
  select m.id, m.content, m.kind, m.subject,
         1 - (m.embedding <=> query_embedding) as similarity
  from memories m
  where m.embedding is not null
    and (filter_subject is null or m.subject = filter_subject)
    and (m.expires_at is null or m.expires_at > now())
    and 1 - (m.embedding <=> query_embedding) >= min_similarity
  order by m.embedding <=> query_embedding
  limit match_count;
$$;

-- ------------------------------------------------------------
-- 5. Row-Level Security
--
-- ⚠️ DECISION 2 — ACCESS PATH. Jarvis is single-user, but the DB is on the
--    public internet. Pick ONE:
--
--    (A) SAFEST — device → your bridge on Slim → Supabase with the SERVICE
--        ROLE key. Keep RLS ON (below); the service role bypasses it. No
--        policies needed, and the powerful key never ships inside the app.
--
--    (B) DIRECT from the device with the ANON key. Then you MUST add RLS
--        policies (e.g. tied to auth.uid() after signing the app in as your
--        one user) — otherwise anyone with the anon key can read/write
--        everything. Policy template is in docs/brain-roadmap.md.
--
--    Enabling RLS now = deny-by-default, so nothing is exposed by accident
--    while you decide. Under path (A) it just works; under path (B) add
--    policies before the app can read/write.
-- ------------------------------------------------------------
alter table state         enable row level security;
alter table memories      enable row level security;
alter table conversations enable row level security;
alter table messages      enable row level security;

-- ------------------------------------------------------------
-- 6. Seed a first digest row so the fast lane has something to stand on.
--    Replace with real content (the agent will keep these fresh later).
-- ------------------------------------------------------------
insert into state (slug, title, body, sort_order) values
  ('owner', 'Who I serve',
   'Reuben — builder. Runs several projects (Cromito, Intercept Padel, the Room). Prefers fast, concise, spoken answers.',
   10)
on conflict (slug) do nothing;
