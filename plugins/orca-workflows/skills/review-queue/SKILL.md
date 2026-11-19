---
name: review-queue
description: >-
  Work through the pull requests waiting on you in a GitHub repo. A script sorts open PRs into new, re-review
  (pushed since your last review), waiting on the author and approved; each PR that needs you gets a review in its
  own Orca worker, and nothing is posted until you approve the draft. It never merges. Use when the user says
  "review-queue", "/review-queue", "review the open PRs", "which PRs are waiting on me", "did I re-review that",
  "PR 올라온 것들 리뷰하자", "나 기다리는 PR 뭐 있어", "재리뷰할 거 있나", or pastes a bare PR URL with no other
  instruction. Requires the GitHub CLI `gh`; the parallel workers and the schedule require Orca
  (https://github.com/stablyai/orca) with its `orca` CLI.
---

# review-queue

A script builds the queue. Your part is reading the code and judging it.

Listing the queue and reviewing a single PR work anywhere `gh` is logged in. One worker per PR, the cleanup and the
schedule need an Orca session.

## 1. Build the queue

```bash
Q="${CLAUDE_PLUGIN_ROOT:-<this skill's folder>}/skills/review-queue/scripts/queue.py"   # Codex: path to this skill
python3 "$Q" [--repo OWNER/NAME] [--author alice,bob] [--requested]
```

- `--repo` defaults to the repo of the current directory.
- `--author` keeps PRs whose author login contains any of the names.
- `--requested` drops `new` PRs that don't request the user by name. A PR that requests only a team is dropped
  too, so say so when you use it.
- `--json` prints the same rows for scripting. `--has-work` exits 0 when something needs a review and 1 when
  nothing does.

The reviewer is whoever `gh` is logged in as. The buckets:

| Bucket | Meaning | Work? |
|---|---|---|
| `re-review` | pushed to, or re-requested, since my last review | yes |
| `new` | I haven't reviewed it | yes |
| `waiting` | I reviewed the current head without approving; the author's turn | no |
| `approved` | I approved the current head | no |
| `mine`, `draft` | my own PRs and drafts | no |

Show the queue as the script printed it, one PR per line, and say how many need a review. A `re-review` on a PR
the user already approved is usually a small follow-up push, so put it last among the work.

The same table answers "what did I review?" and "have I looked since they pushed?": each row carries the last
review's state, date and the sha it was made on.

If the user pasted one PR URL, skip the table and go to step 2 for that PR.

## 2. Review

Get a brief for each PR that needs a review:

```bash
python3 "$Q" --repo OWNER/NAME --brief <number>
```

The brief names the head sha and the CI state. For a re-review it also gives the sha last reviewed, the commits
since, and the diff range to read.

**One PR:** review it in this session, following the brief.

**Several PRs:** give each its own Orca worker, so the reviews run in parallel and each starts with a clean
context. Load Orca's `orchestration` skill and follow it for the dispatch. The shape is:

```bash
git fetch origin <head branch>
python3 "$Q" --repo OWNER/NAME --brief <n> > <scratch>/brief-<n>.md
orca orchestration worker-start --spec-file <scratch>/brief-<n>.md \
  --task-title "Review PR #<n>" --worktree new-child --name review-pr-<n> \
  --base-branch origin/<head branch> --agent <agent> --json
```

Confirm the flags with `orca orchestration worker-start --help`; they change between Orca versions. A PR from a
fork has no `origin/<head branch>`: fetch `pull/<n>/head` into a local branch and base the worktree on that.

Outside Orca, or when the user wants one session, review the PRs here one after another.

What a review covers:

- **Red CI first.** If the brief says CI failed, find the cause (`gh run view <id> --log-failed`) and lead with it.
- **Re-review:** read only the diff since the last review. For each point raised before, say whether it is
  addressed. Then list anything new.
- **First review:** read the PR body and the whole diff, and check the change against the repo's own agent
  instructions (`AGENTS.md`, `CLAUDE.md`) and contribution rules.
- Say what you could not verify: a dependency that isn't checked out here, a number you couldn't re-measure.

## 3. Draft, then post

For each PR, show:

1. a recommended verdict: approve, comment or request changes;
2. the findings, most severe first, with `file:line`;
3. the review body, written in the language the PR uses. If the user is talking to you in another language, add
   a translation for them to read; only the first version is posted.

Ask which form to post in, and post only what the user approved:

```bash
gh pr review <n> --repo OWNER/NAME --approve|--comment|--request-changes --body-file <file>
```

Three rules:

- **Never run `gh pr merge`.** "Go ahead" after a draft means post the review. Merging is a separate request, and
  when the user does ask for it, confirm the PR number first.
- **Don't act on someone else's PR beyond reviewing it.** No closing, no pushing to their branch.
- If the user drops a finding or rewrites the body, post their version.

## 4. Clean up

Once the reviews are posted, remove the review worktrees this run created:

```bash
orca orchestration worker-release ...        # per the orchestration skill
orca worktree rm --worktree <selector> --delete-branch
```

A review worktree has no PR of its own, so a cleanup rule that waits for "linked PR merged" never clears it.
Remove it when its review is posted, its tree is clean and its agent is done. Never use `git worktree remove` or
`rm -rf` on an Orca worktree: both leave the workspace registered with no folder behind it.

## Running it on a schedule

An Orca automation can prompt a session in a worktree that already exists, and that session creates the review
worktrees. `--workspace` is what stops the automation from creating a worktree of its own on every run:

```bash
orca automations create --name "<repo> review queue" \
  --workspace path:<abs path of the worktree you coordinate from> --workspace-mode existing \
  --provider <agent> --trigger "0 10 * * 1-5" --timezone <IANA tz> \
  --precheck "python3 <abs path to queue.py> --repo OWNER/NAME --has-work" \
  --prompt "/orca-workflows:review-queue" --reuse-session     # Codex: "$review-queue"
```

- The precheck skips the run when nothing needs a review, so no session opens on a quiet day. It runs outside the
  agent, so give it an absolute path to `queue.py`; `${CLAUDE_PLUGIN_ROOT}` isn't set there.
- The run stops at step 3 with the drafts on screen, because posting waits for the user.
- `--reuse-session` sends later runs to the previous automation session while it is still open. It isn't the
  session you type in.
- `orca automations run` ignores the precheck, which is how you test the prompt on a day with an empty queue.

## Troubleshooting

- **`gh … failed` after three tries**: the script retries timeouts, dropped connections and an IP allow-list 403,
  which usually mean a network or VPN blip. If it still fails, tell the user and stop; don't guess the queue.
- **`rebased` on a row**: the sha last reviewed is no longer in the PR, so there is no "since my review" diff.
  Review the full diff and compare it with the earlier comments.
- **A PR is missing**: `--requested` and `--author` filter rows out. Run without them.
- **More than 200 open PRs**: the script reads the 200 most recent. Raise the limit in `queue.py`.
