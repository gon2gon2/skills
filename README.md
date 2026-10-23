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

### Orca workflows (`orca-workflows`)

These skills drive other coding agents through [Orca](https://github.com/stablyai/orca). They need the Orca app running and its `orca` CLI on your `PATH`, and they do nothing outside an Orca session.

- **[rather-than-me](./plugins/orca-workflows/skills/rather-than-me/SKILL.md)** — Second opinions from frontier models made by other AI labs. It writes one brief, has those models review it independently (the one you are talking to sits out), and compares their answers with its own view. Works from Claude Code and Codex.
- **[issue-autopilot](./plugins/orca-workflows/skills/issue-autopilot/SKILL.md)** — A scheduled Orca automation that works through a repo's GitHub issues one at a time. A runbook (`AUTOMATION.md`) is the agent's contract, a precheck skips runs with nothing to do, labels and `Depends on:` lines order the work, and each run implements one issue in a fresh worktree and ends in a PR. Templates for the runbook, the precheck and the issue format are included.
