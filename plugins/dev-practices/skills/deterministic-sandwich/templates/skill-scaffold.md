# Scaffold — a new sandwich skill

```
skills/<name>/
  SKILL.md
  scripts/
    collect.py     # bread — auth, fetch, preflight  → collected.json
    write.py       # bread — rules, format, gate     → side effect + exit code
  fixtures/
    collected.json # for re-running the judgment standalone
    judged.json    # for the golden-file test of write.py
```

No script for the judgment — that step *is* the LLM, driven by the doc.

## SKILL.md skeleton

````markdown
---
name: <name>
description: <what it does>. Use when <trigger phrases the user would actually say>.
---

# <Name>

## LLM vs script

Script owns: auth, API calls, filtering, formatting, exit codes, write gate.
You (the LLM) own: exactly one natural-language judgment — <one line>.

❌ Do not call <API> directly              → `scripts/collect.py` does
❌ Do not apply <rule> yourself            → `scripts/write.py` does
❌ Do not group, sort, or reformat rows    → `scripts/write.py` does
✅ <the one judgment>                      → this, and only this, is your job

## Steps

1. `python scripts/collect.py > collected.json`
   Non-zero exit means stop and surface the error — do not work around it.

2. Read `collected.json`. For each entry, <the judgment> and write `judged.json`:

   ```json
   {"items": [{"source_id": "str", "ticket_key": "str|null", "summary": "str"}]}
   ```

   Emit every item you find, including ones you think are irrelevant.
   Do not filter, sort, or format.

3. `python scripts/write.py < judged.json` (dry-run). Show the output as-is.
   After the user confirms, re-run with `--save`.
````

## collect.py skeleton

```python
#!/usr/bin/env python3
"""Bread. Auth + fetch + preflight. Emits collected.json on stdout."""
import json, os, sys

EXIT_OK, EXIT_PRECONDITION, EXIT_UPSTREAM = 0, 2, 3

def main() -> int:
    token = os.environ.get("<SERVICE>_TOKEN")
    if not token:
        print(json.dumps({"error": "missing_credentials"}), file=sys.stderr)
        return EXIT_PRECONDITION
    try:
        entries = fetch_all(token)          # bulk calls, not per-item
    except Upstream as e:
        print(json.dumps({"error": "upstream", "detail": str(e)}), file=sys.stderr)
        return EXIT_UPSTREAM
    json.dump({"config": {...}, "entries": entries}, sys.stdout, ensure_ascii=False)
    return EXIT_OK

if __name__ == "__main__":
    sys.exit(main())
```

## write.py skeleton

```python
#!/usr/bin/env python3
"""Bread. Rules + format + gated write. Reads judged.json on stdin."""
import argparse, json, sys

EXCLUDED = {...}            # every rule is a constant here, never a sentence in the doc
BUCKET_ORDER = [...]        # ordering is explicit

def render(items) -> str:
    kept = [i for i in items if i["status"] not in EXCLUDED]
    ...                     # fixed grouping, fixed sort, fixed link format
    return "\n".join(lines)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--save", action="store_true", help="actually write; default is dry-run")
    args = ap.parse_args()

    judged = json.load(sys.stdin)
    body = render(judged["items"])

    if not args.save:
        print("DRY RUN — would write:\n" + body)
        return 0
    return publish(body)

if __name__ == "__main__":
    sys.exit(main())
```

## Golden-file test

```bash
python scripts/write.py < fixtures/judged.json > /tmp/out
diff /tmp/out fixtures/expected.txt      # no LLM involved; must be exact
```
