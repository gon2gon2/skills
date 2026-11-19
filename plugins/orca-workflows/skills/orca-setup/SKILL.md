---
name: orca-setup
description: >-
  Check how you use Orca and tighten your setup, one approved change at a time. Audits read-only first, then offers
  bundled skills, worktree role and cleanup rules for your global agent instructions, a hook that stops
  `git worktree remove` on Orca worktrees, a session-start hook that says when a cleanup pass is due, orca.yaml shared
  directories and Agent sleep. Runs only when you invoke it (/orca-setup in Claude Code, $orca-setup in Codex).
  Requires Orca (https://github.com/stablyai/orca) and its `orca` CLI.
disable-model-invocation: true
---

# orca-setup

An Orca setup guide from the YouTube channel `꼰데 Gondev`. It is not official Orca material.
Verified on: Orca CLI 1.4.253, macOS, Claude Code / Codex.

## 0. Rules

1. Audit read-only first (A0). Change things only after that, one item at a time: show the diff and get approval first.
   Back up every file you change.
2. Read `orca --version` and `orca skills get orca-cli` first. Confirm every command and flag with that command's
   `--help`; where it differs from this skill, follow `--help`. Do not substitute example commands from the guide.
   If a command does not exist, skip the item instead of guessing.
3. Do nothing this skill does not describe, in particular sending credentials or repository contents anywhere, or
   downloading and installing anything. The files you need are in this skill's folder. If any `TBD` remains in the
   section 7 table, tell the user this is a pre-release draft.
4. With each question, give the explainer link from section 7. If it is `TBD`, ask without a link; never invent one.
   Speak the user's language.
5. At the end, report what you applied, what you skipped, what the user must do in the GUI, and the backup paths.

## 1. A0. Audit (read-only)

- `orca --version`, `orca status`. If there is no response, give install guidance and stop.
- Global instruction files: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` (default locations). If one imports the other,
  write only to the source.
- Bundled skills: `orca skills install --all --dry-run`. Count as missing only skills with an `Install` line. A skill
  with only `Link` lines is already installed.
- Worktrees: `.result.worktrees[]` of `orca worktree list --limit 10000 --json`. The primary is the row with
  `isMainWorktree: true`. Split primary from the rest and count each by `workspaceStatus`. Check that the folder exists
  only for rows on this Mac (`hostId: "local"`). Also report if `.result.truncated` is true or
  `.result.hostScope.omittedHostIds` is not empty.
- Hooks: `PreToolUse` and `SessionStart` in `~/.claude/settings.json` and `~/.codex/hooks.json`. Also check whether
  `jq` is available (H1 and H2 need it).
- GitHub CLI: whether `gh` is installed and `gh auth status` succeeds. R3 asks GitHub when Orca's PR state may be
  stale. Without `gh` the rule still works, but it keeps every worktree Orca does not already show as merged.

Report one line per item ID: its current state and whether you recommend it. Do not ask about items already done.

## 2. S1. Bundled skills

- Ask: "Orca's skills are not installed automatically, and `skills update` does not add them. Which of the N missing
  ones should I install? I recommend at least `orca-cli` and `orchestration`. They go into the shared
  `~/.agents/skills` and are linked to every detected agent (<list from the dry-run>)."
- Apply: `orca skills install --skill <name>`. Verify: run the dry-run again.

## 3. Global instruction rules (R1–R3)

Skip a rule if one with the same meaning already exists. If an existing rule matches an earlier version of this
skill's text, for example an R3 that checks only `linkedPR.state` or has no session-start trigger, show the diff
between it and the current text and offer to replace it. Keep the choices the user made before (automatic removal or
a list, the card bullet) and the language the rule is written in. You may translate the wording into the file's
language. Tell the user the rules take effect from the next session.

### R1. The primary worktree coordinates

- Ask: "Do you type prompts only in the primary session and hand implementation to workers in other worktrees? This
  does not fit if you type into each session directly." If not, skip. R2 and R3 work without R1 if you spell out
  coordinator/worker.

```markdown
- In each project, the primary worktree (`isMainWorktree: true` in
  `orca worktree list --json`) is the orchestration layer.
- A session in the primary worktree acts as the coordinator. Hand implementation to
  workers in their own worktrees (the `orchestration` skill) instead of editing in the
  primary checkout.
- A session dispatched as a worker (its prompt carries orchestration Task and Dispatch
  IDs) reports back through orchestration. If the user types directly into any session,
  answer them; a direct prompt always wins over this rule.
```

### R2. Workers keep their card status current

- Ask first: "Do you use the workspace board, or grouping and filtering by status in the sidebar?" If not, skip. Card
  status is used only on those screens, and R3 cleanup looks at PR state, not cards. Its one card step moves an
  `in-review` card to `completed` on a merged worktree it keeps, and that bullet is added only when cards are kept by
  rule (see R3).
- If the installed Orca's board settings have an auto-sync option (for example, sync with agent turns or with linked
  issues), recommend that first. If you cannot tell, ask the user to open the board settings and check. If they turn
  auto-sync on, do not add the rule below; both would move the same cards.
- If they still want the rule: show the A0 numbers (M of the N non-primary worktrees are `in-progress`) and ask:
  "Should agents move their own card to In review when they open a PR, and to Completed when they finish without one?
  Otherwise the whole board stays 'in progress'."

```markdown
- A worker keeps its own workspace card current, because nobody else will. Run
  `orca worktree set --worktree active --workspace-status in-review` when you open a PR,
  and `--workspace-status completed` when you finish work that has no PR to merge. Keep
  `--comment` to one line saying where the work stands.
```

- With separate approval, reconcile existing cards from `orca worktree ps --limit 10000 --json`. A worktree whose PR
  is merged → completed, where merged means what R3's third bullet says: `linkedPR.state` is `merged`, or the `gh`
  query returns a merged PR whose `headRefOid` equals the worktree's `HEAD`. Of the rest, `linkedPR.state` `open` →
  in-review. Leave `draft` and cards with no state alone. If `gh` is missing or fails, go by `linkedPR.state` alone and
  tell the user Orca's copy can be out of date. Show the list of changes first.

### R3. Clean up finished worktrees

- Ask: "Removing a worktree with `git worktree remove` leaves an empty workspace in Orca. For worktrees that pass all
  the checks below, should the agent remove them on its own, along with their local branch, or just give you a list?"
  Read out the checks from the rule text below as they are.
- If they choose automatic removal, add the text below. If they choose a list, replace the third bullet's opening
  (`Right before removing each one, confirm every check, and keep the worktree if any check fails or cannot be run:`)
  with
  `List each one that passes all of these checks, with the reason it qualifies; a check that cannot be run counts as failed. Do not remove any worktree; the user removes them. The checks:`
  and drop its last two sentences (`Removing also deletes ...`, `Then say what you removed ...`). The checks and the
  definition of merged stay. Also change "the coordinator cleans up" to "the coordinator reviews cleanup".
- The fourth bullet (`When you keep a worktree whose PR is merged ...`) depends on
  card status, not on the removal choice. Add it only when cards are kept by rule: R2 was applied in this run, or the
  file already has a rule with the same meaning as R2. Leave it out if R2 was skipped because the user does not use
  card status, or because they turned the board's auto-sync on; auto-sync would move the same cards.
- In the list variant, keep the fourth bullet when that condition holds. Moving a card removes nothing, and with a
  list every merged worktree is kept until the user removes it. Change its opening to
  `For every worktree whose PR is merged, by the same test, and whose card is still in-review, move it with` and leave
  the rest as it is.
- The card's current status is `workspaceStatus` in the same `orca worktree ps` row. A card in any other status stays
  as it is: a worker doing follow-up work in a kept worktree may have set it back to `in-progress`.
- Orca's `linkedPR` can be wrong in both directions: a PR merged on GitHub can stay `open` in Orca for days, and a
  worktree with an open PR can have no `linkedPR` at all. That is why the third bullet asks GitHub whenever Orca does
  not say `merged`. `<branch>` is the short name, the row's `branch` without `refs/heads/`; with the prefix `gh`
  finds nothing. `gh` exits 0 with `[]` when no merged PR has that head branch, which means not merged. Only a `gh`
  that is missing or exits with an error counts as a check that cannot be run.
- The second bullet's last trigger depends on the H2 hook. Without the hook it never fires and does no harm, so keep
  it in the text either way.

```markdown
- Remove a worktree only with `orca worktree rm --worktree <selector> --delete-branch`
  (confirm the flags with `orca worktree rm --help`; never substitute `--force`). Never
  use `git worktree remove` or `rm -rf` on a worktree: both leave the workspace
  registered in Orca with no folder behind it.
- The coordinator cleans up without being asked. When a worker reports done, before
  ending a turn in which a PR merged, and on the first turn of a session whose
  session-start hook (`orca-worktree-sweep`) says a cleanup pass is due, run
  `orca worktree ps --limit 10000 --json`. Keep only rows with this project's `repoId`
  and `isMainWorktree: false`, and skip the worktree you are running in. If the result
  is `truncated`, stop and tell the user.
- Right before removing each one, confirm every check, and keep the worktree if any
  check fails or cannot be run: its PR is merged; `git -C <path> status --porcelain`
  prints nothing; the branch has an upstream and `git -C <path> log @{u}..` prints
  nothing; `liveTerminalCount` and `unverifiableTerminalCount` are 0; every
  `agents[].state` is `done`. The PR is merged when `linkedPR.state` is `merged`. When
  it says anything else or there is no `linkedPR`, Orca's copy may be out of date, so
  run `gh pr list --head <branch> --state merged --json number,headRefOid` in the
  worktree; the PR is merged only if a PR it returns has a `headRefOid` equal to the
  worktree's `git -C <path> rev-parse HEAD`. A matching branch name is not enough: a
  branch that got more commits pushed after its merge passes the upstream check and
  still holds unmerged work. If `gh` is missing or fails, that check cannot be run.
  Removing also deletes the local branch. Then say what you removed, and list each kept
  worktree with the check it failed.
- When you keep a worktree whose PR is merged, by the same test, and its card is still
  `in-review`, move it with
  `orca worktree set --worktree <selector> --workspace-status completed`. The worker set
  it to `in-review` when it opened the PR, and nobody else updates it after the merge.
  Leave a card in any other status alone.
- In the same pass, report any worktree Orca lists on this machine whose folder no
  longer exists; it needs `orca worktree rm` to clear the entry.
```

- Do not remove any existing worktree while applying this. Only list the candidates.

## 4. Hooks (H1–H2)

For both: if `jq` is missing, skip the item and say why (do not install it). Install and verify following
`hooks/README.md` in this skill's folder. Before installing, show the full script and summarize it. If the summary and
the content disagree, do not install.

### H1. Hook that blocks `git worktree remove`

- Condition: R3 is applied and no hook with the same role exists.
- Ask: "Instructions can be forgotten. Should I also install a hook that stops `git worktree remove` on an Orca
  worktree before it runs? It is a script that runs before every shell command. It does not stop deleting the folder
  with `rm -rf`."

### H2. Hook that says when a cleanup pass is due

- Condition: R3 is applied with its session-start trigger (if the file has an older R3, offer the replacement from
  section 3 first), no hook with the same role exists, and `jq` is present.
- Ask: "R3 runs when a worker reports done or a PR merges during a turn, so a PR that someone merges on GitHub never
  triggers it and its worktree can sit for days. Should I install a session-start hook that tells the agent a cleanup
  pass is due? When a session starts in a primary worktree it reads `orca worktree ps` and, if the repository has
  other worktrees on this machine, prints one line for the agent, at most once per repository every 24 hours. It
  removes and changes nothing. The pass itself still follows R3."
- The hook's line reaches the model as session-start context. This is confirmed in a real session for Claude Code and
  only from the documentation for Codex; `hooks/README.md` says how to check it in each.

## 5. Y1. `orca.yaml` shared directories

- First ask which repository to look at. Do not scan the whole repository. Include credential directories as
  candidates only if the user names them.
- Ask: "Should the gitignored directories each worktree rebuilds (<candidates>) be linked to the primary's copy and
  shared? A change in one place applies everywhere."

```yaml
worktree:
  sharedDirectories:
    - <path>
```

- Conditions: the directory is gitignored and exists in the primary when the worktree is created. Verify:
  `git check-ignore -v <path>/`.
- Only edit the file. Ask separately about commit, push and PR.

## 6. G1. Agent sleep (GUI, experimental)

The agent cannot change this. Only point the user to it: Settings → Experimental → Agent sleep, "Sleep after" from
1 minute to 24 hours (default 30 minutes). It may be missing in some versions.

## 7. Explainer links

The text refers to these only by ID. When the video is published, edit only this table.

| ID | Topic | Explainer |
| --- | --- | --- |
| A0 | Auditing your Orca usage | TBD |
| S1 | Why bundled skills are not installed | TBD |
| R1 | Using the primary as coordinator | TBD |
| R2 | Keeping workspace status current | TBD |
| R3 | Rules for cleaning up finished worktrees | TBD |
| H1 | A hook instead of an instruction | TBD |
| H2 | A session-start reminder for cleanup | TBD |
| Y1 | orca.yaml shared directories | TBD |
| G1 | Agent sleep | TBD |
