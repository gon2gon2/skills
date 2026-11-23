---
name: comment-ratchet
description: Setup wizard that bans code comments in a repo and keeps them out. It inspects the repo, installs a comment lint with a baseline that only shrinks, a CI check, and a repo-local /delete-comment skill, and scaffolds a decisions folder when the repo has none. Use for "comment-ratchet", "/comment-ratchet", "ban comments in this repo", "set up the no-comments lint", "주석 금지 린트 깔아줘", "주석 래칫 세팅", or when someone wants a comment cleanup they can repeat and enforce.
metadata:
  author: gondev
  version: "1.0.0"
  short-description: Install a no-comments lint, ratchet and cleanup skill into a repo.
---

# Comment ratchet

Installs four things into the repo you are in, and nothing that depends on this plugin
afterwards:

| Piece | What it does |
|---|---|
| `<lintDir>/comments.mjs` | Finds comments in TypeScript, JavaScript, Python, shell, SQL and `#`-style config files. `check` fails on a comment line the baseline does not list. `strip` deletes comments and refuses when the syntax tree changes. |
| `<lintDir>/baseline.json` | A fingerprint for every comment line that exists today. It only gets shorter, so old comments can wait and new ones cannot land. |
| CI check | Runs the lint's own tests and `check` on every pull request. |
| `delete-comment` skill | The repeatable cleanup: classify each comment, move decisions and excuses out, strip, lower the baseline. |

## LLM vs script

Scripts own: reading the repo, writing files, the baseline, the check.
You own one judgment: turning what `detect` found into `plan.json`, so the install matches
how this repo already works.

❌ Do not write the installed files by hand → `scripts/install.mjs` does
❌ Do not edit `baseline.json` → the lint does
❌ Do not delete any comment during setup → that is the installed skill's job, later
✅ Decide where things go and how this repo records decisions and files issues

## Steps

1. Collect.

   ```bash
   SKILL="${CLAUDE_PLUGIN_ROOT:-<this skill's folder>}"   # Codex, or installed with `npx skills`: the path to this skill
   [ -d "$SKILL/skills/comment-ratchet" ] && SKILL="$SKILL/skills/comment-ratchet"
   node "$SKILL/scripts/detect.mjs" . > "$SCRATCH/detected.json"
   ```

   `$SCRATCH` is any temporary directory outside the repo.

   Exit 2 means this is not a git repository. Stop and say so. If `installed` is not empty,
   the lint is already here: say where, and offer the installed `delete-comment` skill
   instead of a second install.

2. Judge. Read `detected.json`, look at the two or three files it points to (an existing
   decision record, one workflow, the agent instructions file), and write
   `"$SCRATCH/plan.json"`:

   ```json
   {
     "target": ".",
     "lintDir": "tools/comment-lint",
     "exclude": ["docs/", "**/__snapshots__/"],
     "languages": ["ts", "py", "sh", "sql", "hash"],
     "packageScript": "comments",
     "run": "npm run comments --",
     "skillDirs": [".claude/skills"],
     "rule": "docs/decisions/0001-no-code-comments.md",
     "decisions": { "path": "docs/decisions", "scaffold": true, "howto": "Add a file to `docs/decisions/from-code/` for the area, or a numbered record in `docs/decisions/` for a decision that stands on its own." },
     "issues": { "howto": "File them with `gh issue create`." },
     "ci": { "kind": "github-actions", "runsOn": "ubuntu-latest", "install": "npm ci --ignore-scripts" },
     "verify": "npm test",
     "agentFile": "AGENTS.md"
   }
   ```

   How to fill it:

   | Field | Rule |
   |---|---|
   | `lintDir` | Under the first of `lintDirCandidates` that already holds tooling. With none, `tools/comment-lint`. |
   | `exclude` | Prose and generated or vendored material from `excludeCandidates`: docs, fixtures, snapshots, patches, generated code. A trailing `/` is a path prefix. `*` and `**/` work as globs. Leave source directories in. |
   | `languages` | Drop `ts` when `languages.ts` is absent, or when `tools.typescriptResolvable` is false and the user does not want the dependency. Same for `py` without `python3`. |
   | `packageScript`, `run` | With a `package.json`, set the script name and `run` to the manager's form (`npm run comments --`, `pnpm comments`, `yarn comments`). Without one, set `packageScript` to null and `run` to `node <lintDir>/comments.mjs`. |
   | `skillDirs` | Every entry of `skillDirs` from detect. With none, `.claude/skills`. |
   | `decisions` | If `decisions` lists a place, use it: set `path`, `scaffold: false`, and write `howto` to match the numbering and file layout you saw there. If it is empty, set `scaffold: true` with `docs/decisions`. |
   | `rule` | The record that states the ban. With `scaffold: true` it is `<path>/0001-no-code-comments.md`. Otherwise leave it out now and fill it in step 4. |
   | `issues.howto` | `gh issue create` for a GitHub remote when `tools.gh` is true. Otherwise name the tracker the repo's docs mention, or ask. Include any label or milestone convention you can see. |
   | `ci` | `github-actions` when the repo has workflows, with `runsOn` copied from an existing pull-request workflow, exactly as written. A label that no runner answers leaves the job queued forever. `install` is the repo's install command when `ts` is scanned, otherwise omit it. Anything else: `"kind": "none"`, and tell the user the two commands to add to their pipeline. |
   | `verify` | The command the repo's contributors run before pushing, if one is obvious. |
   | `agentFile` | The first of `agentFiles`, or null. |

   Ask the user only about what detect could not settle: an unknown issue tracker, or two
   decision folders with no clear winner.

3. Write, gated.

   ```bash
   node "$SKILL/scripts/install.mjs" "$SCRATCH/plan.json"
   ```

   This is a dry run. Show the list as it is. After the user agrees, re-run with `--apply`.
   Exit 3 means a file already exists with other content: show which, and use `--force` only
   if the user says to replace it. Exit 4 means the fresh baseline did not pass its own
   check: report the output and stop.

4. Record the rule where the repo keeps decisions. With `scaffold: true` the install wrote
   it. Otherwise write one record in the repo's own format, copying the structure of the
   newest existing record: the ban, the baseline that only shrinks, where a decision goes
   (test or type first, then a record), that an excuse becomes an issue, and what is not
   covered (docstrings, unscanned languages from `notScanned`). Then put its name in
   `rule` in `<lintDir>/config.json` and re-run step 3 with `--apply --force` so the installed
   skill cites it.

5. Report: the files written, the comment-line total and share that `install` printed, the
   languages it found and does not scan, and the next step, which is `/delete-comment <path>`
   on the directory with the most comments. Do not start the cleanup unless asked. Commit
   nothing unless asked.

## What the ratchet catches

- A new comment line in any scanned file, including new files.
- A reworded comment line, since its fingerprint changes.
- A baseline that still lists lines that are gone, so the list cannot drift upward.

It does not catch Python docstrings, comments in languages it does not scan, or text in the
excluded paths. Lint suppressions are not comments here. `scan --directives` lists them, and
the installed skill reviews them.
