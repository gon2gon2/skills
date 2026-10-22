---
name: rather-than-me
description: >-
  Get independent second opinions from frontier models made by other AI labs, run as Orca workers, then compare
  their reviews with your own view. The model you are talking to sits out. Use when the user says "rather-than-me", "/rather-than-me",
  "codex랑 cursor한테 리뷰받아", "astra랑 grok한테 물어봐", "다른 모델 의견 받아봐", "second opinion",
  or wants a plan, design, diff, PR or document reviewed by models other than the one they are talking to.
  Requires Orca (https://github.com/stablyai/orca) with its `orca` CLI; it does nothing outside an Orca session.
---

# rather-than-me

Outside reviewers read the same brief on their own and each writes one Markdown file. You stay the coordinator: you
write the brief, start the workers, wait, read the files, and report where they agree, where they disagree, and what
you think.

This skill runs inside [Orca](https://github.com/stablyai/orca) and drives it through the `orca` CLI. If `orca
status --json` fails, stop and tell the user that Orca is required. Load the version-matched guide first, the way the `orchestration` skill says
(`orca skills get orchestration`), and follow it wherever it differs from the commands below.

## 0. Pick the reviewers

The reviewers are the frontier models of the agents other than you:

| Agent | Model | Output file |
|---|---|---|
| `claude` | `claude-fable-5-1` | `claude-fable.md` |
| `codex` | `gpt-6-astra` | `codex-astra.md` |
| `cursor` | `grok-4.7-high` | `cursor-grok.md` |

- From Claude: Codex and Cursor. From Codex: Claude and Cursor. From any other agent: all three.
- Claude Fable is unavailable under zero data retention. If its worker fails to start for that reason, start it again
  with `claude-opus-5-5` and say so in the report.

Before writing the brief, ask the user one question: add Gemini 4 Argon (`--agent cursor --model
gemini-4-argon-high`, output `cursor-argon.md`) as an extra reviewer? Default to no. Skip the question if the user
already said.

## 1. Write the brief

The reviewers know nothing about this conversation. Write `BRIEF.md` with:

- the goal, and the decision or artifact under review,
- the facts and measurements so far (paths to files they should read, not pasted dumps),
- your current proposal, stated plainly so they can disagree with it,
- 2–5 numbered questions you want answered.

Strip company names, customer data, secrets and anything the user marked private. All reviewers are outside services.

Put it in a review directory: the one the user names, else `<repo>/reviews/<topic>/` if the review belongs to the
repo, else a fresh temporary directory such as `$(mktemp -d)/reviews/<topic>/`.

## 2. Start the workers

Run from the repo (or the directory the reviewers need to read). Create a run, then start every worker in the same
turn so they work in parallel:

```bash
orca orchestration run-create --objective "Independent review of <topic>" --json

spec(){ cat <<EOF
Target: read-only review. Read $DIR/BRIEF.md (and any files it points to) and answer its questions with your own independent opinion.
Change: write your answer as Markdown to $DIR/$1.md (English, concrete, at most ~900 words; disagree with the proposal wherever you think it is wrong).
Constraints: do not modify, create or delete any other file; do not start servers, browsers or installs; no network writes; no git commits.
Ownership: you own only $DIR/$1.md.
Observable acceptance: $DIR/$1.md exists and answers every question in the brief, ending with a concrete recommendation. Send worker_done with --report-path pointing to that file.
EOF
}
# One call per reviewer picked in step 0:
orca orchestration worker-start --spec "$(spec codex-astra)" --task-title "<topic> review (Codex/Astra)" \
  --worktree current --agent codex --model gpt-6-astra --json
orca orchestration worker-start --spec "$(spec cursor-grok)" --task-title "<topic> review (Cursor/Grok)" \
  --worktree current --agent cursor --model grok-4.7-high --json
orca orchestration worker-start --spec "$(spec claude-fable)" --task-title "<topic> review (Claude/Fable)" \
  --worktree current --agent claude --model claude-fable-5-1 --json
```

Keep each worker's `dispatch` id from the output.

## 3. Wait and collect

```bash
orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 590000 --json
```

- Acknowledge each delivery (`--ack <delivery id>`) and keep waiting until every reviewer has reported.
- Answer a `question` from what you know, and escalate to the user only what is theirs to decide.
- When a worker is done, read its file, then `orca orchestration worker-release --dispatch <id> --json`.
- If a worker fails or times out twice, release it and report with the reviews you have. Say so.
- Check `git status`: the reviewers must not have touched anything but their own file.

## 4. Report

Tell the user, in their language:

- each reviewer's bottom line in one or two sentences,
- where they agree, and where they disagree with each other or with the proposal,
- your own call, including where you think a reviewer is wrong and why,
- the paths of `BRIEF.md` and every review file.

Do not act on the reviews (edit code, change plans, file issues) unless the user asks.
