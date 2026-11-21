---
name: review-queue
description: >-
  Work through the pull requests waiting on you in a GitHub repo. A script sorts open PRs into new, re-review
  (pushed since your last review), waiting on the author and approved; each PR that needs you gets a review in its
  own Orca worker, and nothing is posted until you approve the draft. Drafts and review worktrees are kept between
  runs, so a PR is re-reviewed only when it is pushed to and cleaned up when it merges. It never merges. Use when the user says
  "review-queue", "/review-queue", "review the open PRs", "which PRs are waiting on me", "did I re-review that",
  "PR 올라온 것들 리뷰하자", "나 기다리는 PR 뭐 있어", "재리뷰할 거 있나", or pastes a bare PR URL with no other
  instruction. Requires the GitHub CLI `gh`; the parallel workers and the schedule require Orca
  (https://github.com/stablyai/orca) with its `orca` CLI.
---

# review-queue

Two scripts do the bookkeeping. `queue.py` builds the queue, and `drafts.py` keeps each draft between runs and
posts the ones the user approved. Your part is reading the code and judging it.

Listing the queue and reviewing a single PR work anywhere `gh` is logged in. One worker per PR, the review
worktrees and the schedule need an Orca session, and that session is the one the user coordinates from (the
repo's primary worktree). It owns the review worktrees and the drafts; workers only read code and report.

```bash
S="${CLAUDE_PLUGIN_ROOT:-<this skill's folder>}/skills/review-queue/scripts"   # Codex: path to this skill
Q="$S/queue.py"; D="$S/drafts.py"
```

## 1. Build the queue

```bash
python3 "$Q" [--repo OWNER/NAME] [--author alice,bob] [--requested]
```

- `--repo` defaults to the repo of the current directory.
- `--author` keeps PRs whose author login contains any of the names.
- `--requested` drops `new` PRs that don't request the user by name. A PR that requests only a team is dropped
  too, so say so when you use it.
- `--json` prints the same rows for scripting. `--has-work` exits 0 when a run has something to do (a PR to
  review, an approved draft to post, or a reviewed PR that is no longer open) and 1 when it has nothing.

The reviewer is whoever `gh` is logged in as. The buckets:

| Bucket | Meaning | Work? |
|---|---|---|
| `re-review` | pushed to, or re-requested, since my last review | yes |
| `new` | I haven't reviewed it | yes |
| `waiting` | I reviewed the current head without approving; the author's turn | no |
| `approved` | I approved the current head | no |
| `mine`, `draft` | my own PRs and drafts | no |

A saved draft changes what counts as work. A row marked `draft: <verdict> @<sha>` already has a draft for its
current head that the user hasn't posted, so it is not reviewed again. `draft: … out of date` means the PR was
pushed to after the draft, and it is reviewed again from that draft. The first line counts both: "N to review,
M drafted and not posted".

Show the queue as the script printed it, one PR per line, and say how many need a review. A `re-review` on a PR
the user already approved is usually a small follow-up push, so put it last among the work.

The same table answers "what did I review?" and "have I looked since they pushed?": each row carries the last
review's state, date and the sha it was made on.

If the user pasted one PR URL, skip the table and go to step 3 for that PR.

## 2. Clean up what merged

The queue ends with `## reviewed, no longer open` when a PR with a saved draft has merged or closed. Its review
worktree is no longer needed. For each one, when the worktree's tree is clean (`git -C <path> status --porcelain`
prints nothing) and no agent is running in it:

```bash
orca worktree rm --worktree path:<worktree> --delete-branch
python3 "$D" forget <n> --repo OWNER/NAME
```

Keep the worktree and say why when a check fails. Never use `git worktree remove` or `rm -rf` on an Orca
worktree: both leave the workspace registered with no folder behind it. A review worktree has no PR of its own,
so a cleanup rule that waits for "linked PR merged" never clears it; this step is what does.

Leave every other review worktree alone. A PR that is still open keeps its worktree, posted or not, because the
next push is reviewed there.

## 3. Review

Get a brief for each PR that needs a review:

```bash
python3 "$Q" --repo OWNER/NAME --brief <number>
```

The brief names the head sha and the CI state. For a re-review it also gives what to start from (the last posted
review, or a draft that was never posted), the commits since, and the diff range to read.

**One PR:** review it in this session, following the brief.

**Several PRs:** give each its own Orca worker, so the reviews run in parallel and each starts with a clean
context. Load Orca's `orchestration` skill and follow it for the dispatch.

Each PR has one review worktree, named `review-pr-<n>`, for as long as the PR is open. Check
`orca worktree ps --json` for it first.

It doesn't exist yet:

```bash
git fetch origin <head branch>
python3 "$Q" --repo OWNER/NAME --brief <n> > <scratch>/brief-<n>.md
orca orchestration worker-start --spec-file <scratch>/brief-<n>.md \
  --task-title "Review PR #<n>" --worktree new-child --name review-pr-<n> \
  --base-branch origin/<head branch> --agent <agent> --json
```

It exists: bring it to the PR's head, then start the worker in it.

```bash
git -C <worktree> fetch origin <head branch>
git -C <worktree> merge --ff-only origin/<head branch>   # refused after a rebase: git -C <worktree> switch --detach origin/<head branch>
orca orchestration worker-start --spec-file <scratch>/brief-<n>.md \
  --task-title "Re-review PR #<n>" --worktree path:<worktree> --agent <agent> --json
```

Confirm the flags with `orca orchestration worker-start --help`; they change between Orca versions. A PR from a
fork has no `origin/<head branch>`: fetch `pull/<n>/head` into a local branch and base the worktree on that.

Outside Orca, or when the user wants one session, review the PRs here one after another.

What a review covers:

- **Red CI first.** If the brief says CI failed, find the cause (`gh run view <id> --log-failed`) and lead with it.
- **Re-review:** read only the diff since the last review. For each point raised before, say whether it is
  addressed. Then list anything new. When the earlier review was a draft nobody saw, the new draft replaces it:
  keep the points that still stand and drop the ones the new commits fix.
- **First review:** read the PR body and the whole diff, and check the change against the repo's own agent
  instructions (`AGENTS.md`, `CLAUDE.md`) and contribution rules.
- Say what you could not verify: a dependency that isn't checked out here, a number you couldn't re-measure.

## 4. Save the draft, then post what the user approves

Save every finished review, with the sha it was made on:

```bash
python3 "$D" save <n> --repo OWNER/NAME --sha <reviewed sha> --verdict approve|comment|request-changes \
  --body-file <file> --summary "<one line>" --worktree <review worktree>
```

The body is written in the language the PR uses. Once a worker's draft is saved, release the worker per the
orchestration skill and keep its worktree.

Then show the user each draft:

1. the recommended verdict;
2. the findings, most severe first, with `file:line`;
3. the review body. If the user is talking to you in another language, add a translation for them to read; only
   the saved version is posted.

Ask which form to post in, and post only what the user approved:

```bash
python3 "$D" post <n> --repo OWNER/NAME [--as approve|comment|request-changes]
```

`post` sends the saved body with `gh pr review`. It refuses when the PR was pushed to after the draft, is no
longer open, or was already posted, so an approval that arrives late can't post a review of old code. When it
refuses because of a push, say so and review the PR again.

`python3 "$D" list --repo OWNER/NAME` shows every saved draft and its status. "Post #12 as approve" in a later
turn means the same `post` command; check `list` first if you no longer have the draft in context.

The user can also approve outside this session. A program that takes their answer (a button in a chat app)
records it with `drafts.py approve <n> --as <verdict>`, and the queue then ends with `## approved, not posted
yet`. Post those at the start of the run, before anything else:

```bash
python3 "$D" post --approved --repo OWNER/NAME
```

Never run `approve` yourself. It stands for the user's decision, and `post --approved` trusts it.

Four rules:

- **Never run `gh pr merge`.** "Go ahead" after a draft means post the review. Merging is a separate request, and
  when the user does ask for it, confirm the PR number first.
- **Don't act on someone else's PR beyond reviewing it.** No closing, no pushing to their branch.
- If the user drops a finding or rewrites the body, save their version over the draft (`save` again, same sha),
  then post it.
- A verdict only the agent chose is a recommendation. Post with the verdict the user named.

## Running it on a schedule

An Orca automation prompts the coordinating session on a timer. Each run does steps 1 to 4 up to the saved
drafts: it posts the drafts approved since the last run, cleans up merged PRs, reviews what is new or was pushed
to, leaves alone every PR whose current head already has a draft, and stops with the drafts on screen. Posting waits for the user. Because finished work is
skipped, the schedule can be as frequent as hourly.

```bash
orca automations create --name "<repo> review queue" \
  --workspace path:<abs path of the primary worktree> --workspace-mode existing \
  --provider <agent> --trigger "0 9-19 * * 1-5" --timezone <IANA tz> \
  --precheck "python3 <abs path to queue.py> --repo OWNER/NAME --has-work" \
  --prompt "/orca-workflows:review-queue scheduled run" --reuse-session     # Codex: "$review-queue scheduled run"
```

Flags change between Orca versions, so check `orca automations create --help` before running it.

- Run it in the primary worktree, with `--workspace-mode existing`. The review worktrees outlive a run, so a
  session in a new worktree per run would lose track of them, and nothing is created per run anyway: each review
  gets its own worker worktree in step 3.
- The precheck skips the run when there is nothing to review, post or clean up, so no session opens on a
  quiet hour. It runs outside the agent, so give it an absolute path to `queue.py`; `${CLAUDE_PLUGIN_ROOT}` isn't
  set there.
- `--reuse-session` sends later runs to the previous automation session while it is still open. It isn't the
  session you type in.
- `orca automations run` ignores the precheck, which is how you test the prompt on a quiet day.

### Telling something else about new drafts (optional)

Nothing more is needed when the user reads the drafts in Orca. To also hand them to another program (a chat bot,
a notifier), end the automation prompt with the command to run, for example
`/orca-workflows:review-queue scheduled run, then notify with "<command>"`, and finish the run with:

```bash
python3 "$D" notify --repo OWNER/NAME --cmd "<command>"
```

It writes the new drafts, and the reviews posted since the last notice, to `digest.json` in the state folder,
runs `<command> <path to digest.json>`, and marks them announced when the command exits 0. Each entry carries the
PR number, title, url, author, reviewed sha, verdict, summary, body, worktree path and a `status` of `ready` or
`posted`. Only run a command the user put in the prompt or gave you directly.

That program answers through this session, never through the workers or GitHub. When the user approves a draft
there, it runs `drafts.py approve <n> --as <verdict>` and then `orca automations run <automation id>`, and the
run it starts posts the review.

## Where the drafts live

`<state>/<OWNER>__<NAME>/pr-<n>.json` and `pr-<n>.md`, where `<state>` is `--state-dir`, then
`$REVIEW_QUEUE_STATE`, then `~/.local/state/review-queue`. Deleting the folder only forgets the drafts: the next
run reviews those PRs again from what is on GitHub.

## Troubleshooting

- **`gh … failed` after three tries**: the script retries timeouts, dropped connections and an IP allow-list 403,
  which usually mean a network or VPN blip. If it still fails, tell the user and stop; don't guess the queue.
- **`rebased` on a row**: the sha last reviewed is no longer in the PR, so there is no "since my review" diff.
  Review the full diff and compare it with the earlier comments.
- **`gh pr review failed` from `post`**: it tries once, because a retry could post twice. Look at the PR before
  posting again.
- **A PR is missing**: `--requested` and `--author` filter rows out. Run without them.
- **More than 200 open PRs**: the script reads the 200 most recent. Raise the limit in `queue.py`.
