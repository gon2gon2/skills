---
name: issue-autopilot
description: >-
  Set up and run an Orca automation that implements a repo's GitHub issues one at a time on a schedule: a runbook
  (AUTOMATION.md) the agent follows, a precheck script that skips runs with nothing to do, issue labels and
  dependency lines that order the work, and a fresh worktree per run that ends in a PR. Use when the user says
  "issue-autopilot", "AUTOMATION.md 만들어줘", "매시간 이슈 하나씩 구현하게", "자동화 루프 세팅", "orca automation으로
  이슈 처리", "let an agent work through the issues", or when an existing loop stalls, skips every run or needs new
  issues. Requires Orca (https://github.com/stablyai/orca) with its `orca` CLI and the GitHub CLI `gh`.
---

# issue-autopilot

An Orca automation wakes up on a schedule, runs a precheck, and when there is work, starts an agent in a fresh
worktree of the default branch. The agent reads `AUTOMATION.md`, takes one eligible issue, implements it, runs the
issue's acceptance checks, opens a PR and either merges it or hands it to a human. Issues are the queue; the runbook
is the contract.

This skill drives Orca through its CLI. If `orca status --json` fails, stop and tell the user that Orca is required.
Read the version-matched reference before creating or editing an automation, and follow it wherever it differs from
the commands below:

```bash
orca skills get orca-cli --reference automations
orca automations create --help
```

## When it fits

It works when the work can be cut into issues that each have a checkable definition of done: commands whose output
proves the change works. It does not fit open-ended design, work that needs a person's taste at every step, or
anything whose checks need production access. Keep those as human checkpoints (step 4).

## 1. Settle the decisions with the user

Ask only what you cannot read from the repo:

- **Repo and branch**: which repo, and which ref each run starts from (normally `origin/<default branch>`).
- **Schedule**: hourly is a good default. One run takes one issue, so the schedule sets the pace.
- **Agent**: provider (`claude`, `codex`, ...) and model/effort for `--extra-agent-args`.
- **Merge policy**: may the agent merge its own PR when every check passes, or does every PR wait for a human? A
  permission classifier or branch protection may refuse an agent's merge anyway; decide what happens then (step 6).
- **Safety list**: what the agent must never touch or do in this repo (deploys, secrets, vendored code, outbound
  services). Ask; do not guess.
- **Local environment**: services the checks need, how to start them, and files the checks need that git does not
  carry (virtualenvs, caches, large local assets, `.env`).

## 2. Write the runbook, precheck and labels

Copy and fill in the templates next to this file:

- `templates/AUTOMATION.md` goes to the repo root. Fill every `<...>` placeholder, keep the section order, and put the
  project-specific context (where things live, how to run checks) in section 2.
- `templates/automation-precheck.sh` goes to `scripts/automation-precheck.sh`. It must exit 0 only when a run can do
  useful work right now.
- If the machine has several `gh` accounts, add a two-line wrapper (`scripts/gh`) that pins the repo owner's account,
  and tell the runbook to use it for every GitHub command:

  ```bash
  #!/bin/bash
  GH_TOKEN="$(command gh auth token --user "<owner-account>")" exec gh "$@"
  ```

Create the labels once:

```bash
gh label create auto --description "Ready for the automation to implement" --color 0E8A16
gh label create in-progress --description "An automation run has claimed this" --color FBCA04
gh label create needs-human --description "Waiting for a person's decision or review" --color D93F0B
```

Show the user the filled runbook before committing it. Commit it to the default branch (the runs start from there),
with the user's go-ahead.

## 3. Lock and precheck: how runs avoid each other

Runs must not overlap: two agents on the same issue waste the run, and two agents on shared local services break
each other's checks. The template uses a lock file in the repo's **git common dir**
(`git rev-parse --git-common-dir`), which every worktree of the repo shares, so a run in one worktree sees the lock
taken by a run in another:

- the agent writes the lock when it claims an issue and removes it as its last step;
- the precheck skips while the lock is younger than a TTL (default 3 h), so a run that died does not block the loop
  forever, only for the TTL.

The precheck also skips when GitHub is unreachable, when a PR labelled `needs-human` is open (the loop waits for the
human instead of piling up work on top of an unreviewed change), and when no issue is eligible. Every skip prints one
line; Orca records it in the run history.

## 4. Write the issues

Each issue is a spec the agent implements without asking anyone. Use `templates/issue.md`:

- **Why**: the problem, with evidence (a failing output, a report line).
- **Change**: what to build, at the level of files and behaviour. Narrow enough for one run.
- **Acceptance**: commands to run and what their output must show. This is the definition of done. A check the agent
  cannot run counts as failed, so every command must work on this machine.
- `Depends on: #a, #b` on its own line: the issue is eligible only once all of them are closed.
- `Part of #n` linking a roadmap issue, if there is one.

Order comes from issue numbers: the runbook takes the lowest-numbered eligible issue. A follow-up filed later runs
after every older issue unless an older issue lists it under `Depends on:`. Never create a dependency cycle; the loop
would skip both issues forever.

For decisions that belong to a person (what to build next, a trade-off, a review), file an issue labelled
`needs-human` without `auto`, say in its body that the automation must not pick it, and list the issues whose results
it needs under `Depends on:`. The loop stops there on its own when nothing else is eligible.

## 5. Create the automation, test it, then enable it

Create it disabled, with a new worktree per run from the default branch:

```bash
orca automations create --name "<repo>: implement next auto issue" \
  --repo path:<abs repo path> --workspace-mode new-per-run --base-branch origin/<default branch> \
  --trigger hourly --timezone <IANA tz> \
  --precheck "bash <abs repo path>/scripts/automation-precheck.sh" --precheck-timeout 120 \
  --provider claude --extra-agent-args="--model <model> --effort <effort>" \
  --prompt "<prompt below>" --disabled --json
```

Keep the prompt short and point it at the runbook, so the rules live in one versioned file:

> You are the scheduled implementation run for <owner>/<repo>. Read AUTOMATION.md at the root of this worktree
> completely and follow it exactly: pick at most one eligible issue labelled auto, implement it on its own branch, run
> every Acceptance check, open a PR, and merge it yourself only when every rule in AUTOMATION.md allows it; otherwise
> label it needs-human and explain in a PR comment. Stop when the run's issue is merged or handed to a human.

Then:

1. Run the precheck by hand from the repo root. It should print `run: N candidate issue(s)`.
2. Trigger one run with `orca automations run <id> --json` and watch it to the end. Check that it claimed the issue,
   wrote and removed the lock, opened a PR with the acceptance output, and cleaned up its labels.
3. Enable it: `orca automations edit <id> --enabled --json`.

## 6. Operate it

```bash
orca automations runs --id <id> --json     # history: started, skipped (with the precheck's line), failed
orca automations show <id> --json          # schedule, next run, precheck, args
orca worktree list --json                  # one worktree per run; finished ones pile up
```

When the loop stalls, check in this order:

- **Every run skips "previous run still active"**: a run died holding the lock. Look at the last run's session. If it
  is gone, remove the lock and drop `in-progress` from its issue; the next run resumes from the branch and PR it left.
- **A run ended without a PR**: the usual cause is a command started in the background (`&`, `nohup`, a tool's
  background mode) followed by the end of the agent's turn. An automation session is never woken up again, so the
  run stops right there with the lock held. The runbook's foreground rule exists for this; if it happened anyway,
  tighten the issue's Acceptance commands so each finishes within one command timeout.
- **Every run skips "PR needs a human: #n <url>"**: a run handed its PR to you, either because a check failed or
  because a permission classifier or branch protection refused its merge. `needs-human` is a GitHub label, so Orca
  shows it only through this precheck line in the run history. Read the PR's last comment, then merge or close it,
  and the loop continues.
- **Every run skips "no open auto issues"** but issues are open: check their labels and `Depends on:` lines (a closed
  dependency the agent did not close, or a cycle).
- **A check is flaky**: the agent should file an issue for it and add it to the `Depends on:` of the issues whose
  results it would invalidate, not fix it inside an unrelated issue. Make sure the runbook says so.

Remove finished run worktrees now and then (`orca worktree rm`), but never one whose PR is still open.

## Rules for this skill

- Never put company names, secrets, tokens or customer data in the runbook, issues or PRs. The agent reads all of
  them and may quote them.
- The automation must not be able to edit its own controls: the runbook lists `AUTOMATION.md`, the precheck script and
  the Orca automation under things it must not touch. Changes go through a `needs-human` issue.
- Do not enable the automation before one supervised run has gone end to end.
