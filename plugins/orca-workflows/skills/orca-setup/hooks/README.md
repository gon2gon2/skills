# orca-setup hooks

Two hooks for Claude Code and Codex. `orca-worktree-guard` stops `git worktree remove` on a worktree Orca manages.
`orca-worktree-sweep` tells the agent at session start that a worktree cleanup pass is due. Each installs on its own.

Both require `jq` (included with macOS 15 and later). Without it they do nothing, so skip installing them.

`sh <this folder>/test.sh` tests both against a fake `orca` and never touches real worktrees or your stamp files. The
last line must be `N passed, 0 failed`.

## orca-worktree-guard

A PreToolUse hook that stops `git worktree remove` on a worktree Orca manages, before it runs, and suggests the
`orca worktree rm` command instead. Paths Orca does not know about pass through.

### Install

1. Copy `orca-worktree-guard.sh` from this folder to `~/.agents/hooks/` and make it executable. Do not point at the
   plugin cache path directly; it changes with every version.
2. Claude Code: add this to `hooks.PreToolUse` in `~/.claude/settings.json`.

   ```json
   {
     "matcher": "Bash",
     "hooks": [
       { "type": "command", "command": "sh \"$HOME/.agents/hooks/orca-worktree-guard.sh\"", "timeout": 10 }
     ]
   }
   ```

3. Codex: add the same entry at the **end** of the `hooks.PreToolUse` array in `~/.codex/hooks.json`. Putting it
   earlier shifts the index of Orca's own hook trust state. Afterwards the user must trust it in Codex with `/hooks`.

### Verify

1. Run `test.sh` as above.
2. Feed only the payload with the path `<wt>` of a real Orca worktree that is not a main worktree (the command is
   not run). It must exit 2 with the message.

   ```bash
   printf '{"tool_input":{"command":"git worktree remove <wt>"}}' | sh ~/.agents/hooks/orca-worktree-guard.sh
   ```

3. Check that it fires in an agent session (Claude Code and Codex separately). First confirm that
   `test -e /nonexistent-orca-guard-check` fails (the path does not exist). Open a new session and have the agent run
   the command below, with `<wt>` as an absolute path in quotes.

   ```bash
   git -C /nonexistent-orca-guard-check worktree remove "<wt>"
   ```

   If the hook fires, the command is blocked before it runs. If it does not, git fails right away because the `-C`
   directory does not exist, so the worktree is not removed. Seeing git's `cannot change to` error means the hook is
   not registered.

### Limits and undo

- This guards against mistakes; it is not a security boundary. It does not see:
  - deleting the folder directly, as in `rm -rf <wt>`
  - commands inside `sh -c "..."` or `bash -c "..."`
  - paths built from variables or `$(...)`
  - commands passed to `xargs`
  - wrappers it does not know, for example `rtk git ...`
  - paths that differ from the managed path only in letter case
  - glob and brace expansion in the target, as in `.../repo-wt*` or `.../{repo-wt}`
  - commands inside backticks
  - worktrees past the first 10000 that `orca worktree list` returns
- It looks past wrappers such as `command`, `env` and `sudo`, and past shell keywords such as `then`, `do` and `{`.
  Heredoc bodies and comments are treated as data, not commands, and ignored.
- git finds a worktree by its last path component, so for a target written as a bare name the hook asks git
  (`git worktree list`, read-only) which worktree of that repository the name means, and blocks if Orca manages it.
- The main worktree of a repository passes through. git refuses to remove it.
- If `jq` or `orca` is missing, or the app does not respond, it lets the command through.
- To bypass once, put `ORCA_WT_GUARD=off` directly in front of the `git worktree remove` it should exempt. It covers
  that one removal; others in the same command line are still checked.
- Undo: remove the hook entry you added and the script file.

## orca-worktree-sweep

A SessionStart hook that prints one line for the agent when a worktree cleanup pass is due. The cleanup rule (R3 in
`SKILL.md`) runs when a worker reports done or a PR merges during a turn, so a PR that someone merges on GitHub never
triggers it. This hook adds a trigger at session start. It is read-only: it runs
`orca worktree ps --limit 10000 --json` and nothing else against Orca, makes no network calls and does not use `gh`.
The agent does the pass, including the `gh` recheck, following the rule in its instructions. Install it only together
with an R3 that has the session-start trigger, otherwise the line has no rule to point at.

It prints the line when the session's working directory is the main worktree of a repository Orca knows (or a folder
inside it) and that repository has at least one other worktree on this machine. In any other worktree, or outside
Orca, it prints nothing. The line looks like this:

```text
Orca worktree cleanup pass due for /path/to/repo: non-primary worktrees on this machine: 4, missing folders: 1. Run the cleanup pass from your instructions on the first turn of this session. (orca-worktree-sweep: read-only, at most one notice per repository every 24 hours.)
```

It prints at most once per repository every 24 hours. The time of the last notice is kept in a stamp file,
`${XDG_STATE_HOME:-$HOME/.local/state}/orca-worktree-sweep/<repoId>.stamp`, outside the repository and the plugin
cache.

### How the line reaches the model

- The hook reads the payload on stdin and uses two fields, `cwd` and `source`. Both agents document them for
  SessionStart. If `cwd` is absent it uses the directory it was started in. When `source` is `compact` it prints
  nothing, because the session is in the middle of its work.
- It prints plain text on stdout and exits 0. Claude Code adds a SessionStart hook's plain-text stdout to the model's
  context. Checked in a real session with Claude Code 2.1.328: the model saw the line as
  `SessionStart:startup hook success: <line>`, and the payload carried `cwd` and `source`.
- Codex documents the same contract (`cwd` and `source` on stdin; "Plain text on `stdout` is added as extra developer
  context"), read at <https://developers.openai.com/codex/hooks> for codex-cli 0.166.0. It has **not** been confirmed
  in a real Codex session: Codex runs only hooks the user has trusted with `/hooks`, and the probe was not trusted.
  Step 4 below is how to confirm it.

### Install

1. Copy `orca-worktree-sweep.sh` from this folder to `~/.agents/hooks/` and make it executable. Do not point at the
   plugin cache path directly; it changes with every version.
2. Claude Code: add this to `hooks.SessionStart` in `~/.claude/settings.json`.

   ```json
   {
     "hooks": [
       { "type": "command", "command": "sh \"$HOME/.agents/hooks/orca-worktree-sweep.sh\"", "timeout": 10 }
     ]
   }
   ```

3. Codex: add the same entry at the **end** of the `hooks.SessionStart` array in `~/.codex/hooks.json`. Putting it
   earlier shifts the index of Orca's own hook trust state. Afterwards the user must trust it in Codex with `/hooks`.

### Verify

1. Run `test.sh` as above.
2. Feed only the payload, with `<primary>` as the path of a main worktree that has other worktrees. It must print
   the line and exit 0. The throwaway state directory keeps this run from using up today's real notice.

   ```bash
   printf '{"cwd":"<primary>","source":"startup"}' | XDG_STATE_HOME=$(mktemp -d) sh ~/.agents/hooks/orca-worktree-sweep.sh
   ```

3. Run the same command with the path of a worktree that is not a main worktree. It must print nothing.
4. Check that the line reaches the model (Claude Code and Codex separately). Delete that repository's stamp file if
   there is one, open a new session in `<primary>` and ask: "Did a session-start hook say a worktree cleanup pass is
   due? Quote the line." If the agent cannot quote it, the hook is not registered, not trusted (Codex), or its output
   does not reach the model in that agent.

### Limits and undo

- It only says a pass is due. It does not check PR state, so the line appears for a repository whose worktrees are
  all still in use, once every 24 hours.
- It counts worktrees on this machine only (`hostId: "local"`), and at most the first 10000 that
  `orca worktree ps` returns. If the list was truncated the line says so.
- The 24 hours run from the last notice, per repository, for every agent that shares the state directory. A notice
  that Claude Code received is not repeated in a Codex session the same day.
- A session in a worker worktree never gets the line, so the pass waits for the next session in the primary.
- The stamp is written before the line is printed. If the agent ignores the line, or the session ends before its
  first turn, the next notice is still 24 hours away. Delete the stamp file to get one sooner.
- If the stamp file cannot be written, it prints nothing, so a broken state directory silences it. It does not fall
  back to notifying in every session.
- If `jq` or `orca` is missing, or the app does not respond, it prints nothing and the session starts as usual.
- To turn it off for one session, start the agent with `ORCA_WT_SWEEP=off` in the environment.
- Undo: remove the hook entry you added, the script file and the `orca-worktree-sweep` state directory.
