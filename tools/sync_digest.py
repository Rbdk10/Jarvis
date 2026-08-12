#!/usr/bin/env python3
"""
Jarvis digest sync — Phase 5.

Scans ~/Dev, summarises every project from its real files (manifests, README,
git — no LLM, so it's robust on a schedule), and upserts the summaries into the
Supabase `state` table: the fast brain's cached digest. This is what makes Jarvis
fluent across ALL your dev projects, and keeps it current automatically.

Owns `proj_*` rows only. Hand-curated rows (owner / current_focus / preferences,
and the curated project rows listed in CURATED_SKIP) are never touched. Removed
projects are pruned so the digest doesn't drift. Idempotent.

Run:   python3 tools/sync_digest.py            # scan + upsert
       python3 tools/sync_digest.py --dry-run  # print what it would write, no DB
Creds: tools/.env.digest  (SUPABASE_REF + SUPABASE_SERVICE_KEY, gitignored)
Skip:  tools/digest.exclude (optional, one dir name per line)
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEV = Path.home() / "Dev"
HERE = Path(__file__).resolve().parent
ENV = HERE / ".env.digest"
EXCLUDE_FILE = HERE / "digest.exclude"

# Projects already covered by richer, hand-written rows — don't auto-manage these.
CURATED_SKIP = {
    "Cromito", "Opportunity", "jarvis-app",
    "intercept-padel-mobile", "intercept.webapp", "intercept_padel", "interceptHW",
}

PROJECT_MARKERS = {
    "package.json", "pyproject.toml", "requirements.txt", "setup.py", "Cargo.toml",
    "go.mod", "mix.exs", "composer.json", "Gemfile", "README.md", "readme.md", "README.MD",
}


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


def slugify(name):
    return "proj_" + re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def git_last_active(d):
    try:
        out = subprocess.run(
            ["git", "-C", str(d), "log", "-1", "--format=%cd", "--date=short"],
            capture_output=True, text=True, timeout=8)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return None


def detect_stack(d):
    names = {p.name for p in d.iterdir()}
    tags = []
    if any(n.endswith(".xcodeproj") for n in names):
        tags.append("iOS/Swift")
    if "package.json" in names:
        try:
            pkg = json.loads((d / "package.json").read_text(errors="ignore"))
            deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
            if "next" in deps: tags.append("Next.js")
            elif "expo" in deps: tags.append("Expo/React Native")
            elif "react" in deps: tags.append("React")
            elif "vue" in deps: tags.append("Vue")
            else: tags.append("Node")
        except Exception:
            tags.append("Node")
    if names & {"pyproject.toml", "requirements.txt", "setup.py"}: tags.append("Python")
    if "Cargo.toml" in names: tags.append("Rust")
    if "go.mod" in names: tags.append("Go")
    if "mix.exs" in names: tags.append("Elixir/Phoenix")
    if "composer.json" in names: tags.append("PHP")
    if "Gemfile" in names: tags.append("Ruby")
    if "supabase" in names: tags.append("Supabase")
    return ", ".join(dict.fromkeys(tags))


def description(d):
    for mf, key in (("package.json", "description"), ("composer.json", "description")):
        if (d / mf).exists():
            try:
                v = json.loads((d / mf).read_text(errors="ignore")).get(key)
                if v and v.strip():
                    return v.strip()
            except Exception:
                pass
    for tf in ("pyproject.toml", "Cargo.toml"):
        if (d / tf).exists():
            m = re.search(r'(?m)^\s*description\s*=\s*"([^"]+)"', (d / tf).read_text(errors="ignore"))
            if m:
                return m.group(1).strip()
    # Generic scaffold READMEs — the framework's default text, not a real description.
    boilerplate = (
        "this template provides a minimal setup", "bootstrapped with", "create-next-app",
        "angular cli", "this project was generated", "get started by editing", "vite with hmr",
        "minimal setup to get react working", "official plugins are available",
        "run the development server", "local development server", "expand the eslint",
    )
    starts = ("open ", "once the server", "navigate to", "first,", "you can start")
    for rn in ("README.md", "readme.md", "README.MD"):
        if (d / rn).exists():
            for raw in (d / rn).read_text(errors="ignore").splitlines():
                s = raw.strip()
                # Skip headings, HTML, badges, list/table items, quotes.
                if not s or s[0] in "#<-*|>" or s.startswith("![") or s.startswith("[!"):
                    continue
                s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)   # [text](url) -> text
                s = re.sub(r"https?://\S+", "", s)                # bare URLs
                s = re.sub(r"[*_`]", "", s).strip()
                low = s.lower()
                if len(s) <= 15 or low.startswith(starts) or any(b in low for b in boilerplate):
                    continue
                return s[:200]
    return None


def is_project(d):
    try:
        names = {p.name for p in d.iterdir()}
    except Exception:
        return False
    return bool(names & PROJECT_MARKERS) or ".git" in names or any(n.endswith(".xcodeproj") for n in names)


def build_rows():
    exclude = set()
    if EXCLUDE_FILE.exists():
        exclude = {l.strip() for l in EXCLUDE_FILE.read_text().splitlines()
                   if l.strip() and not l.startswith("#")}
    rows, order = [], 100
    for d in sorted((p for p in DEV.iterdir() if p.is_dir()), key=lambda p: p.name.lower()):
        if d.name in CURATED_SKIP or d.name in exclude or not is_project(d):
            continue
        try:
            desc = description(d) or "(no description found in repo)"
            body = desc
            meta = []
            stack = detect_stack(d)
            if stack:
                meta.append(f"Stack: {stack}")
            active = git_last_active(d)
            if active:
                meta.append(f"last active {active}")
            if meta:
                body += " · " + " · ".join(meta)
            rows.append({"slug": slugify(d.name), "title": d.name,
                         "body": body[:600], "include_in_digest": True, "sort_order": order})
            order += 1
        except Exception as e:
            print(f"  ! skipped {d.name}: {e}", file=sys.stderr)
    return rows


def rest(env, method, path, body=None, extra_headers=None):
    url = f"https://{env['SUPABASE_REF']}.supabase.co/rest/v1/{path}"
    headers = {
        "apikey": env["SUPABASE_SERVICE_KEY"],
        "Authorization": f"Bearer {env['SUPABASE_SERVICE_KEY']}",
        "Content-Type": "application/json",
    }
    headers.update(extra_headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.status


def sync(env, rows):
    if not rows:
        print("no project rows found — refusing to prune (safety)")
        return
    # 1. Upsert current projects.
    status = rest(env, "POST", "state?on_conflict=slug", rows,
                  {"Prefer": "resolution=merge-duplicates,return=minimal"})
    print(f"upserted {len(rows)} project rows (HTTP {status})")
    # 2. Prune stale proj_* rows (projects removed from ~/Dev).
    keep = ",".join(r["slug"] for r in rows)
    try:
        rest(env, "DELETE", f"state?slug=like.proj_*&slug=not.in.({keep})",
             extra_headers={"Prefer": "return=minimal"})
        print("pruned any stale proj_* rows")
    except urllib.error.HTTPError as e:
        print(f"prune skipped (HTTP {e.code})", file=sys.stderr)


def main():
    env = load_env()
    rows = build_rows()
    print(f"— {len(rows)} projects —")
    for r in rows:
        print(f"  {r['slug']}: {r['body'][:90]}")
    if "--dry-run" in sys.argv:
        print("(dry run — nothing written)")
        return
    try:
        sync(env, rows)
    except urllib.error.HTTPError as e:
        sys.exit(f"sync failed HTTP {e.code}: {e.read().decode()[:300]}")


if __name__ == "__main__":
    main()
