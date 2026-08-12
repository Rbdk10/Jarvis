# Companion protocol — agent-directed narration (Phase B)

The app runs a **live companion**: while the agent works, the on-device fast brain
keeps the user company with spoken updates, then the agent's real answer lands as
the final reply. Phase A narrates from the app's side by *guessing* from the
`status` stream. **Phase B** lets the agent narrate *itself* — precise, first-person
lines the app just voices. This is what makes "keep me updated on what you're doing"
accurate instead of approximate.

This doc is the contract the **Slim bridge / agent** must satisfy. The app side is
already shipped (it listens for these messages); the bridge just has to send them.

## The messages

All frames are JSON over the existing WebSocket, same channel as `reply`/`status`.

### `say` — interim narration (implemented, app-side ✅)
```json
{"type": "say", "text": "Found the config — patching the timeout now."}
```
- Spoken **immediately** in the Jarvis voice, *without ending the turn*. The agent
  keeps working; more `say`s (and eventually one `reply`) can follow.
- The **first** `say` of a turn makes the app's auto-narrator **yield** — from then
  on the agent is driving the narration, so the app won't talk over it or guess.
- Contrast:
  - `reply` = the **final** answer. Ends the turn; cuts any narration; re-arms the mic.
  - `status` = a **technical** label (tool name, step). The app may narrate *from* it
    in Phase A, but `say` is preferred — it's already in the user's voice.

### `ask` — mid-task question (implemented, app-side ✅)
```json
{"type": "ask", "text": "There are two config files — the prod one, or staging?"}
```
- The app speaks the question, **opens the mic**, and routes the user's spoken (or,
  in text mode, typed) answer **straight back into the same turn** as a normal
  `{"type":"message"}` — no new-turn treatment, no opener, no fast-brain re-routing.
  The companion resumes narrating after the answer lands.
- The turn stays alive across the whole exchange: you may `ask` more than once, then
  `say` progress, then finish with one `reply`. Only `reply` ends the turn.
- This is what makes it a **conversation, not a monologue**. The rule for the agent:
  **when you'd otherwise assume, `ask` instead.** Ambiguous target, missing detail,
  a destructive/irreversible step, more than one reasonable interpretation → ask a
  single, specific question and wait for the answer rather than guessing.
- Keep questions **one at a time** (the app captures one spoken answer per `ask`) and
  short. If you have several, ask the most decision-blocking one first.

## How the agent should narrate (guidance)

- **First person, Jarvis voice**: dry, unflappable, lightly British. "Right, digging
  through the inbox now." — not "Executing search_email(query=…)."
- **Short**: one spoken sentence, < ~15 words. It's audio, not a log line.
- **At meaningful milestones**, not every tool call: starting a phase, a notable
  finding, a slow step ("this build will take a minute"), a change of plan. Aim for
  one line every ~5–15s on a long task; silence is fine on a quick one.
- **Never** the final result in a `say` — that's what `reply` is for. Don't say
  "done" and then also `reply`; just `reply`.
- **Truthful**: only narrate what's actually happening. The whole point is that these
  are the agent's real words, not the app's guess.

## Where to emit (Slim)

Wherever the bridge already emits `{"type":"status", ...}` to the app, add a parallel
path that emits `{"type":"say", "text": "..."}` for user-facing narration. Practically:
a small tool/hook the agent can call (e.g. `jarvis_say("…")`) that pushes a `say`
frame over the same socket the `reply` goes out on. Keep `status` too (useful trace +
Phase-A fallback when the agent doesn't narrate).

### Slim implementation (live)

- **Plugin** `~/.claude/plugins/marketplace/plugins/jarvis/server.ts` — MCP tools
  `jarvis_say` and `jarvis_ask` write `{type:'say'|'ask'}` lines to
  `/tmp/jarvis/outbox.jsonl`. `jarvis_ask`'s tool + channel instructions tell the agent
  to ask (not assume) and to **end its turn after asking** — the user's answer arrives
  as the next inbound message and resumes the same session. (Takes effect on the next
  `claude` session restart.)
- **Relay** `~/.claude/scripts/jarvis-server.ts` — forwards a fixed `specialTypes`
  allowlist as-is (everything else is wrapped as a `reply`). `ask` is on that list, so
  the frame reaches the app unchanged. `ask` is buffered like `reply` (delivered on a
  quick reconnect), unlike `say`/`context` which are drop-on-miss. (Live now — relay
  restarted.)

## Fallback behaviour (already handled by the app)

- No `say` at all → Phase A auto-narration from `status` (unchanged).
- Fast brain off (no key / over the spend cap) → the canned filler, as before.
- Text mode → narration is currently voice-only; `say` is ignored there (a future
  option is to render interim `say`s as transcript notes).
