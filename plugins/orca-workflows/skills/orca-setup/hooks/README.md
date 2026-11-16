# orca-worktree-guard

Orca 가 관리하는 워크트리를 `git worktree remove` 로 지우려 하면 실행 전에 막고 `orca worktree rm` 명령을 알려 주는 PreToolUse 훅.
Orca 에 등록되지 않은 경로는 통과한다.

필요한 것: `jq` (macOS 15 이상 기본 포함). 없으면 훅이 아무것도 막지 않으니 설치하지 말고 건너뛴다.

## 설치

1. 이 폴더의 `orca-worktree-guard.sh` 를 `~/.agents/hooks/` 에 복사하고 실행 권한을 준다. 플러그인 캐시 경로는 버전마다 바뀌니 직접 가리키지 않는다.
2. Claude Code: `~/.claude/settings.json` 의 `hooks.PreToolUse` 에 추가한다.

   ```json
   {
     "matcher": "Bash",
     "hooks": [
       { "type": "command", "command": "sh \"$HOME/.agents/hooks/orca-worktree-guard.sh\"", "timeout": 10 }
     ]
   }
   ```

3. Codex: `~/.codex/hooks.json` 의 `hooks.PreToolUse` 배열 **끝에** 같은 항목을 넣는다. 앞에 넣으면 Orca 훅의 신뢰 상태 인덱스가 밀린다.
   넣은 뒤 사용자가 Codex 에서 `/hooks` 로 직접 신뢰해야 한다.

## 검증

1. `sh <이 폴더>/test.sh` — 가짜 `orca` 로 돌아서 실제 워크트리는 건드리지 않는다. 마지막 줄이 `N passed, 0 failed` 여야 한다.
2. 실제 Orca 워크트리 경로 `<wt>` 로 payload 만 넣는다(명령은 실행되지 않는다). exit 2 와 안내가 나와야 한다.

   ```bash
   printf '{"tool_input":{"command":"git worktree remove <wt>"}}' | sh ~/.agents/hooks/orca-worktree-guard.sh
   ```

3. 에이전트 세션에서 실제로 걸리는지 본다(Claude Code, Codex 각각). 먼저 `test -e /nonexistent-orca-guard-check` 가
   실패하는지(그 경로가 없는지) 확인한다. 새 세션을 열고 에이전트에게 아래 명령을 실행하게 한다. `<wt>` 는 절대 경로로, 따옴표로 감싼다.

   ```bash
   git -C /nonexistent-orca-guard-check worktree remove "<wt>"
   ```

   훅이 걸리면 실행 전에 막힌다. 안 걸려도 `-C` 디렉터리가 없어 git 이 바로 실패하니 워크트리는 지워지지 않는다.
   git 의 `cannot change to` 오류가 보이면 훅이 등록되지 않은 것이다.

## 한계와 되돌리기

- 실수를 줄이는 장치이지 보안 경계가 아니다. 다음은 보지 못한다:
  - `rm -rf <wt>` 처럼 폴더를 직접 지우는 것
  - `sh -c "..."`, `bash -c "..."` 안에 든 명령
  - 변수나 `$(...)` 로 만든 경로
- `command`, `env`, `sudo` 같은 감싸는 명령은 건너뛰고 본다. heredoc 본문은 명령이 아니라 데이터로 보고 무시한다.
- `jq`·`orca` 가 없거나 앱이 응답하지 않으면 통과시킨다.
- 한 번만 우회하려면 명령 앞에 `ORCA_WT_GUARD=off` 를 붙인다.
- 되돌리기: 추가한 훅 항목과 스크립트 파일을 지운다.
