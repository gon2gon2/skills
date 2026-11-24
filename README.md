# skills

Agent skills.

## Installation

Install any skill with [`skills`](https://www.npmjs.com/package/skills):

```bash
npx skills add gon2gon2/skills                          # pick from the list
npx skills add gon2gon2/skills --skill rather-than-me   # one skill
```

Each group of skills below is also a plugin, and this repo is a plugin marketplace for Claude Code and Codex.

Claude Code:

```bash
claude plugin marketplace add gon2gon2/skills
claude plugin install dev-practices@gon2gon2-skills
claude plugin install orca-workflows@gon2gon2-skills
```

Codex:

```bash
codex plugin marketplace add gon2gon2/skills
codex plugin add dev-practices@gon2gon2-skills
codex plugin add orca-workflows@gon2gon2-skills
```

## Skills

### Dev practices (`dev-practices`)

- **[deterministic-sandwich](./plugins/dev-practices/skills/deterministic-sandwich/SKILL.md)** — Script – LLM – script. Make the LLM do less: every deterministic step lives in a script, and the LLM does exactly one natural-language judgment.
- **[comment-diet](./plugins/dev-practices/skills/comment-diet/SKILL.md)** — A setup wizard that bans code comments in a repo and keeps them out. It reads how the repo already works (languages, decision records, skill folders, CI runners, issue tracker) and installs a comment lint for TypeScript, JavaScript, Python, shell, SQL and `#`-style config files, a baseline of comment fingerprints that only shrinks, a pull-request check, and a repo-local `delete-comment` skill. That skill sorts each comment into tautology, stale, excuse or decision, moves decisions into a test, a type or a record, files issues for excuses, and strips comments only when the syntax tree stays the same. Needs Node 22 and git; Python and TypeScript only when the repo has those files.

### Orca workflows (`orca-workflows`)

These skills drive other coding agents through [Orca](https://github.com/stablyai/orca). They need the Orca app running and its `orca` CLI on your `PATH`, and they do nothing outside an Orca session.

- **[rather-than-me](./plugins/orca-workflows/skills/rather-than-me/SKILL.md)** — Second opinions from frontier models made by other AI labs. It writes one brief, has those models review it independently (the one you are talking to sits out), and compares their answers with its own view. Works from Claude Code and Codex.
- **[issue-autopilot](./plugins/orca-workflows/skills/issue-autopilot/SKILL.md)** — A scheduled Orca automation that works through a repo's GitHub issues one at a time. A runbook (`AUTOMATION.md`) is the agent's contract, a precheck skips runs with nothing to do, labels and `Depends on:` lines order the work, and each run implements one issue in a fresh worktree and ends in a PR. Templates for the runbook, the precheck and the issue format are included.
- **[review-queue](./plugins/orca-workflows/skills/review-queue/SKILL.md)** — The pull requests waiting on you, reviewed without merging anything. A script sorts a repo's open PRs into new, re-review (pushed since your last review), waiting on the author and approved. Each PR that needs you gets a review in its own Orca worker, and a review is posted only in the form you pick after reading the draft. A precheck flag lets an Orca automation run it on a schedule and skip days with an empty queue.
- **[orca-setup](./plugins/orca-workflows/skills/orca-setup/SKILL.md)** — Checks how you use Orca and tightens your setup, one approved change at a time. It audits read-only first, then offers Orca's bundled skills, worktree role and cleanup rules for your global agent instructions, a hook that stops `git worktree remove` on Orca worktrees, a session-start hook that says when a cleanup pass is due, `orca.yaml` shared directories and Agent sleep. It runs only when you invoke it (`/orca-setup` in Claude Code, `$orca-setup` in Codex).
- **[adopt-pet](./plugins/orca-workflows/skills/adopt-pet/SKILL.md)** — Turns your own character art into an Orca pet that reacts to your agents: it runs while they work, waits when one needs you and reads when work is done. It slices grid images, fits frames into Orca's 8×9 sheet, fills the rows you have no art for, checks the bundle against Orca's import rules and renders a preview. You bring the art; the pet is imported from Orca's status bar.
