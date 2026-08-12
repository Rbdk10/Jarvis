# Jarvis brain roadmap — from "locked to agent" to "trustworthy auto"

**North star:** *fast is the main value; then as smart and capable as possible.*
**Rule:** never regress. You keep living in agent mode until auto is proven, then flip.

Today: you run Jarvis in `agent` mode because the `chatbot` fast lane is empty
(no context). The plan grounds the fast lane, makes routing trustworthy, then
retires the manual mode switch — Jarvis routes itself, with the full agent
always underneath.

---

## The end state
One routed Jarvis over a tiered ladder. The router picks the entry tier; each
tier escalates upward when out of depth.

| Tier | Brain | Speed | Handles |
|------|-------|-------|---------|
| 0 | local rules / preset commands | instant | "remember X", presets, obvious task verbs |
| 1 | warm fast brain (Haiku + Supabase memory) | sub-second | chit-chat + recall + "what's the status of X" |
| 2 | specialists (Room agents: Evie, …) | seconds | domain work with tools |
| 3 | full agent (Opus on Slim) | slow | hard reasoning + live actions |

The `chatbot`/`agent` toggle stops being something you *operate* — both survive
as **tiers the router selects**. A manual "pin a tier" override stays as an
escape hatch.

---

## Phases (each one keeps Jarvis usable throughout)

### Phase 0 — Foundation *(you're here)*
- [ ] Create the Supabase project.
- [ ] **Decide the embedding model** → set `vector(N)` in `supabase/schema.sql`.
- [ ] Run `supabase/schema.sql`.
- [ ] **Decide the access path** (service-role-via-bridge vs anon+RLS — see below).
- [ ] Seed a real first digest in `state` (replace the sample `owner` row).
- No app change yet. **No regression:** still living in agent mode.

### Phase 1 — Ground the fast lane (make "chatbot" actually good)
- [ ] App reads the digest → injects it as the fast brain's **cached** system block.
- [ ] App embeds the utterance → `match_memories()` → appends hits **after** the cache breakpoint.
- [ ] Write-back: "remember X" → `memories` row (embed on write or lazily).
- [ ] Add the grounding guardrail to the fast-brain prompt: *answer only from the
      memory you're given; if it's not there, escalate to the agent.*
- Test by manually flipping to `chatbot` and checking it now answers real
      questions. **Default stays `agent`.** No regression.

### Phase 2 — Make the fast lane genuinely fast (latency wins)
- [ ] Stream Haiku → sentence-chunk → streaming TTS (start speaking sentence 1).
- [ ] ElevenLabs **Flash v2.5** over the WebSocket endpoint, `auto_mode`, US-pinned.
- [ ] Trim the ~400ms endpoint / semantic turn-detection.
- These also speed the agent's spoken output. Still default `agent`.

### Phase 3 — Make routing trustworthy
- [ ] Generalise `FastBrain.decide()` to return `{ tier, model, specialist?, reason }`
      instead of `{ chat | task }` — routing rides on the answer call (no extra latency).
- [ ] Add Tier-0 local heuristics for obvious cases (0 network).
- [ ] Keep escalation (fast brain → agent) + the instant filler that hides the
      escalate tax.
- [ ] Log every turn's route to `messages` (tier/model/reason/latency).
- Test `auto` on the side. **Default still `agent`.**

### Phase 4 — Flip the default ⭐
- [ ] When `auto` routes your real usage correctly, change the default from
      `agent` to `auto`. Keep "pin a tier" as an override.
- This is the moment the modes dissolve into one routed Jarvis.

### Phase 5 — Add tiers & keep memory fresh
- [ ] Wire Room specialists (Evie, …) as Tier-2 routes.
- [ ] State-sync job: the agent on Slim refreshes the `state` digest on a
      schedule (reuse the Evie scheduler pattern).

### Phase 6 — Tune with data
- [ ] Use the `messages` routing log to find mis-routes and slow turns; tune
      heuristics and escalation thresholds.

---

## RLS policy template (only if you chose path B: anon key from the device)
After signing the app in as your single user, scope every table to that user.
Simplest single-user form (allow the authenticated user full access):

```sql
create policy "owner rw" on state
  for all to authenticated using (true) with check (true);
-- repeat for memories, conversations, messages
```

For true multi-tenant safety add an `owner uuid default auth.uid()` column and
`using (owner = auth.uid())`. For a personal assistant, path A (service role via
the bridge) is simpler and keeps the strong key out of the app.

---

## The one thing everything hinges on
**Router decision quality.** A grounded fast lane + a good router = fast *and*
accurate on everyday turns. A bad router = fast *wrong* answers. That's why
Phase 4 (flip the default) only happens after Phase 3 proves the routing on your
real usage — and why escalation + the filler exist as the safety net.
