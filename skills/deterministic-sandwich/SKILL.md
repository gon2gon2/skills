---
name: deterministic-sandwich
description: Designs and refactors agent skills/commands so every deterministic step lives in a script and the LLM does exactly one natural-language judgment. Use when building a new skill or slash command, when an existing one is slow, flaky, or burns tool calls, or when the user mentions "deterministic sandwich", "thin LLM", "LLM vs script", or splitting judgment from determinism.
metadata:
  author: gondev
  version: "2.0.0"
  short-description: Script - LLM - script. Make the LLM do less.
---

# Deterministic Sandwich

> **"The way to use an LLM better is to give it less to do."**

Wrap every deterministic step in a script and leave the LLM exactly one job:
natural-language judgment.

```
┌─────────────────────────────────┐
│  collect   (script)             │  bread — auth, I/O, fetch, config
├─────────────────────────────────┤
│  judge     (LLM)                │  filling — ONE natural-language judgment
├─────────────────────────────────┤
│  write     (script)             │  bread — rules, format, write-gate, exit code
└─────────────────────────────────┘
    collected.json  →  judged.json      ← JSON files, never conversation state
```

## The One Question

For every step of the workflow ask: **"does this step need natural-language judgment?"**

- **YES → LLM** — and it gets exactly one job
- **NO → script** — deterministic, testable, repeatable

Rule of thumb: if you can write an assertion for the output, it belongs in a script.

## The Three Layers

| Layer | Owns | Never |
|-------|------|-------|
| **collect** (script) | auth/credentials (env only), API calls (bulk, not per-item), pagination/retries, config, preflight checks | interpreting what text means |
| **judge** (LLM) | exactly ONE of: extraction (free text → JSON), classification (→ closed-set label), intent mapping (NL → flags) | tool calls, filtering, sorting, formatting, deciding success |
| **write** (script) | business rules as constants, fixed ordering/formatting, the gated write, exit codes | second-guessing `judged.json` |

Layers hand off through typed JSON files. Schemas live in this doc, next to the step
that produces them. Keep the raw text in `collected.json` so a bad judgment can be
re-run without re-fetching. If two steps need judgment: merge them into one prompt with
a richer schema, or split into two skills — never two LLM calls in one skill.

The judge prompt must say what **not** to do:

> Extract every action item from `entry.body` into the schema below. Emit every item
> you find, including ones you think are irrelevant. Do not filter, sort, or format —
> the script decides what is excluded.

That instruction is load-bearing. An LLM that filters "helpfully" is how items go
missing, unreproducibly.

## The Contract Block

An undocumented split decays: next run, the LLM sees a task it *could* do and does it.
Every sandwich skill carries this block in its doc, above the steps:

```markdown
## LLM vs script

Script owns: auth, API calls, rule/filter application, formatting, exit codes, write gates.
You (the LLM) own: exactly one natural-language judgment — <one line>.

❌ Do not call <API> directly            → the script does
❌ Do not apply <rule/filter> yourself   → the script does
❌ Do not format bullets/links/order     → the script does
✅ <the one judgment>                    → this, and only this, is your job
```

The ❌ lines matter more than the ✅ line — the positive instruction doesn't stop the
LLM from *also* doing the five other things it noticed it could do. Write them as
concrete refusals ("do not call the tracker API directly"), not advice ("prefer the
scripts").

## The Write Gate

A prohibition in a doc is a request; a gate in a script is a guarantee. Every command
that writes to the outside world defaults to dry-run and requires `--save`:

```python
if not args.save:
    print("DRY RUN — would POST:\n" + json.dumps(payload, indent=2))
    return 0
```

When an action must *never* happen, don't gate it — make it unreachable:

```python
assert endpoint.endswith("/draft"), "this command is draft-only by construction"
```

Doc-level "confirm with the user first" is the weakest level; never rely on it alone.

## Anti-Patterns

| Anti-pattern | Sign | Fix |
|---|---|---|
| LLM orchestrates | Doc is a 6+ step procedure of tool calls; "for each X, call Y" loops in prose | Collapse into collect → judge → write; bulk calls in the script |
| LLM applies rules | "exclude", "only if", thresholds and status names in prose | A `filter()` in English, run on a nondeterministic interpreter — make it a constant in the script |
| LLM formats output | "group by", "summarize nicely"; two runs word things differently | Script emits the final shape; the doc's only output instruction is "show as-is" |
| LLM swallows failure | A run that wrote nothing reports "done"; failure handling is "tell the user" | Script owns exit codes and failure notification; distinguish "empty input" from "broke" |
| Implicit split | The split exists but no doc says the LLM must not bypass the scripts | Add the contract block |
| State in conversation | "using what you found above, write..." | Boundary JSON files; each step re-runnable standalone |

## Workflow

Same for new skills and refactors:

- [ ] Write out every step in plain language, numbered (refactor: count tool calls per run first, as a baseline)
- [ ] Tag each step with The One Question
- [ ] Collapse the NOs into `collect` (before the judgment) and `write` (after)
- [ ] Keep exactly one YES; define the two JSON schemas
- [ ] Paste the contract block; gate every real write behind `--save`
- [ ] Stability test: run twice on identical input — output must be byte-identical

```bash
python scripts/write.py < fixtures/judged.json > /tmp/a
python scripts/write.py < fixtures/judged.json > /tmp/b
diff /tmp/a /tmp/b        # non-empty diff = formatting still lives in the LLM
```

Expect the step count to collapse — a long LLM-orchestrated procedure typically becomes
3 steps with 1 LLM call, and per-item API calls become one bulk call.

Scaffold for new skills: [templates/skill-scaffold.md](templates/skill-scaffold.md)

## When NOT to Use

- The output **is** the creative work (drafting, ideation) — no deterministic core exists
- Open-ended exploration where the plan can't be known upfront — do the opposite: hand
  the agent tools and let it run
- One-off prototype — drawing the boundary costs more than it pays

## Related Patterns

Functional Core, Imperative Shell (inverted — here determinism is the outside);
Single Responsibility Principle, applied to the LLM; Anti-Corruption Layer (the JSON
boundaries stop nondeterminism leaking downstream).
