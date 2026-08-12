#!/usr/bin/env python3
"""
Phase 6 — router telemetry report.

Reads the Supabase `messages` log (written by the app on every turn) via the
service key, and shows how Jarvis is actually routing:
  • tier mix (local / fast / agent) and escalation rate
  • latency percentiles per tier (end-of-speech → first audio)
  • the slowest "fast" turns (the fast lane not being fast — investigate)
  • the most common escalation reasons

Use it to spot mis-routes and slow paths, then tune Router.looksLikeAgentTask
and the fast-brain prompt. Needs telemetry — which only accumulates once the
router build (47+) is on the phone and used. Empty until then.

Run:  python3 tools/analyze_routes.py
"""
import json
import sys
import urllib.request
from pathlib import Path

ENV = Path(__file__).resolve().parent / ".env.digest"


def load_env():
    if not ENV.exists():
        sys.exit(f"missing {ENV} — needs SUPABASE_REF + SUPABASE_SERVICE_KEY")
    env = {}
    for line in ENV.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def fetch(env, limit=5000):
    url = (f"https://{env['SUPABASE_REF']}.supabase.co/rest/v1/messages"
           f"?select=tier,escalated,latency_ms,route_reason,content,created_at"
           f"&order=created_at.desc&limit={limit}")
    req = urllib.request.Request(url, headers={
        "apikey": env["SUPABASE_SERVICE_KEY"],
        "Authorization": f"Bearer {env['SUPABASE_SERVICE_KEY']}",
    })
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def pctile(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    k = (len(s) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return round(s[lo] + (s[hi] - s[lo]) * (k - lo))


def main():
    rows = fetch(load_env())
    if not rows:
        print("No telemetry yet.\nUse the router build (47+) for a bit, then re-run — "
              "every turn logs its route here.")
        return

    total = len(rows)
    print(f"═══ Jarvis routing — {total} turns "
          f"({rows[-1]['created_at'][:10]} → {rows[0]['created_at'][:10]}) ═══\n")

    tiers = {}
    for r in rows:
        tiers.setdefault(r.get("tier") or "?", []).append(r)

    print("Tier mix:")
    for tier, rs in sorted(tiers.items(), key=lambda kv: -len(kv[1])):
        lats = [r["latency_ms"] for r in rs if r.get("latency_ms") is not None]
        share = 100 * len(rs) / total
        p50, p90 = pctile(lats, 0.5), pctile(lats, 0.9)
        lat = f"p50 {p50}ms · p90 {p90}ms" if lats else "no latency data"
        print(f"  {tier:<9} {len(rs):>4} ({share:4.0f}%)   {lat}")

    esc = sum(1 for r in rows if r.get("escalated"))
    print(f"\nEscalation rate: {esc}/{total} ({100*esc/total:.0f}%) "
          "— fast brain handed up to the agent")

    fast = [r for r in rows if r.get("tier") == "fast" and r.get("latency_ms")]
    if fast:
        slow = sorted(fast, key=lambda r: -r["latency_ms"])[:5]
        print("\nSlowest FAST turns (fast lane that wasn't fast — investigate):")
        for r in slow:
            print(f"  {r['latency_ms']:>5}ms  “{(r.get('content') or '')[:60]}”")

    reasons = {}
    for r in rows:
        if r.get("escalated"):
            reasons[r.get("route_reason") or "?"] = reasons.get(r.get("route_reason") or "?", 0) + 1
    if reasons:
        print("\nTop escalation reasons:")
        for reason, n in sorted(reasons.items(), key=lambda kv: -kv[1])[:5]:
            print(f"  {n:>4}  {reason}")

    print("\nTune: if a class of question keeps escalating, either add a Tier-0 "
          "heuristic for it, or give the fast brain the memory to answer it.")


if __name__ == "__main__":
    main()
