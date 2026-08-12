# Jarvis brain tools (Phases 5–6)

Two local jobs that feed and observe Jarvis's Supabase memory. Both read
`tools/.env.digest` (gitignored) for `SUPABASE_REF` + `SUPABASE_SERVICE_KEY`.

## `sync_digest.py` — the self-maintaining project digest (Phase 5)
Scans `~/Dev`, summarises every project from its real files (manifests, README,
git — no LLM), and upserts the summaries into the Supabase `state` table (the
fast brain's cached digest). This is what makes Jarvis fluent across **all** your
dev projects and keeps it current.

- Owns `proj_*` rows; leaves hand-curated rows (owner / current_focus /
  preferences + the `CURATED_SKIP` projects) alone. Prunes removed projects.
- Exclude a repo: add its `~/Dev` folder name to `tools/digest.exclude` (one per line).
- ⚠️ The digest is readable with the app's publishable key — keep anything
  sensitive out of it (use the locked `memories` table or the agent instead).

```sh
python3 tools/sync_digest.py --dry-run   # preview, no writes
python3 tools/sync_digest.py             # scan + upsert + prune
```

### Schedule it (daily 06:30) — makes it self-maintaining
```sh
cp tools/com.jarvis.digest-sync.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.jarvis.digest-sync.plist
```
Stop it: `launchctl unload ~/Library/LaunchAgents/com.jarvis.digest-sync.plist`
Logs: `/tmp/jarvis-digest-sync.log` / `.err`

## `analyze_routes.py` — router telemetry report (Phase 6)
Reads the `messages` log (written by the app on every turn) and reports how
Jarvis is routing: tier mix, escalation rate, latency percentiles per tier, the
slowest fast turns, and the top escalation reasons. Use it to spot mis-routes and
slow paths, then tune `Router.looksLikeAgentTask` / the fast-brain prompt.

```sh
python3 tools/analyze_routes.py
```
Needs telemetry — only accumulates once the router build (47+) is on the phone
and used. Empty until then.
