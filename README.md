# skills

Agent skills.

## Installation

Install any skill with [`skills`](https://www.npmjs.com/package/skills):

```bash
npx skills add gon2gon2/skills                          # pick from the list
npx skills add gon2gon2/skills --skill rather-than-me   # one skill
```

The Orca skills are also packaged as the `orca-workflows` plugin. This repo is a plugin marketplace for Claude Code and Codex.

Claude Code:

```bash
claude plugin marketplace add gon2gon2/skills
claude plugin install orca-workflows@gon2gon2-skills
```

Codex:

```bash
codex plugin marketplace add gon2gon2/skills
codex plugin add orca-workflows@gon2gon2-skills
```

## Skills

- **[deterministic-sandwich](./skills/deterministic-sandwich/SKILL.md)** — Script – LLM – script. Make the LLM do less: every deterministic step lives in a script, and the LLM does exactly one natural-language judgment.

### Orca workflows

These skills drive other coding agents through [Orca](https://github.com/stablyai/orca). They need the Orca app running and its `orca` CLI on your `PATH`, and they do nothing outside an Orca session.

- **[rather-than-me](./plugins/orca-workflows/skills/rather-than-me/SKILL.md)** — Second opinions from frontier models made by other AI labs. It writes one brief, has those models review it independently (the one you are talking to sits out), and compares their answers with its own view. Works from Claude Code and Codex.
