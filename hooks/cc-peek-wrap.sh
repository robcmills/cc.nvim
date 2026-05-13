#!/usr/bin/env bash
# cc.nvim PreToolUse hook: wraps long-running Bash tool calls with `tee` so
# the output streams to a per-tool log file under the user's cache dir.
# cc.nvim's :CcPeek tails that file in a floating window. Short-timeout calls
# and non-Bash tools pass through unchanged.
#
# Security:
# - umask 077 → files mode 0600, dirs mode 0700 (per-user readable only).
# - Logs land under $XDG_CACHE_HOME/cc-peek/ (or ~/.cache/cc-peek/), never /tmp.
# - session_id and tool_use_id are validated against ^[A-Za-z0-9_-]+$ before
#   being used in any path or shell substitution.
#
# Stdin: PreToolUse JSON payload (see claude-code/src/utils/hooks.ts).
# Stdout: hookSpecificOutput JSON with updatedInput.command, or empty for
#         pass-through. Always exits 0.

set -eu
umask 077

input=$(cat)

# Best-effort field extraction. Prefer jq when available; fall back to a
# small Python helper (Python ships with macOS and most Linux distros).
extract() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 // empty" <<<"$input"
  else
    python3 -c '
import json, sys
data = json.load(sys.stdin)
path = sys.argv[1].lstrip(".").split(".")
cur = data
for p in path:
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        cur = None
        break
if cur is None:
    sys.exit(0)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
' "$1" <<<"$input"
  fi
}

tool_name=$(extract '.tool_name')
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

timeout=$(extract '.tool_input.timeout')
# Only wrap calls that explicitly opt into a long timeout (>= 30s). Calls
# without a timeout are typically quick — pass them through unchanged.
case "$timeout" in
  ''|*[!0-9]*) exit 0 ;;
esac
if [ "$timeout" -lt 30000 ]; then
  exit 0
fi

session_id=$(extract '.session_id')
tool_use_id=$(extract '.tool_use_id')
command=$(extract '.tool_input.command')

if [ -z "$session_id" ] || [ -z "$tool_use_id" ] || [ -z "$command" ]; then
  exit 0
fi

# Defense in depth: only allow characters known-safe in path components, so
# $LOG cannot be coerced into traversal or shell-meaningful sequences even
# if the upstream payload is malformed.
case "$session_id" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac
case "$tool_use_id" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/cc-peek"
log_dir="$cache_root/$session_id"
log="$log_dir/$tool_use_id.log"
mkdir -p "$log_dir"

# Wrap the original command. `set -o pipefail` so the original exit code
# propagates through `tee`. Braces preserve operator precedence inside the
# original command. stderr is merged into stdout so peekers see both.
wrapped="set -o pipefail; { $command; } 2>&1 | tee $(printf '%q' "$log")"

# Emit the hookSpecificOutput payload. Build JSON via jq or Python to
# guarantee proper escaping of the command string.
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg cmd "$wrapped" \
    --argjson timeout "$timeout" \
    '{ hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: { command: $cmd, timeout: $timeout }
      } }'
else
  python3 -c '
import json, sys
cmd = sys.argv[1]
timeout = int(sys.argv[2])
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "updatedInput": {"command": cmd, "timeout": timeout},
    }
}))
' "$wrapped" "$timeout"
fi
