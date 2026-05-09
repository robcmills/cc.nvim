#!/usr/bin/env bash
# cc.nvim PreToolUse hook: wraps long-running Bash tool calls with `tee` so
# the output streams to a per-tool log file. cc.nvim's :CcPeek tails that file
# in a floating window. Short-timeout calls and non-Bash tools pass through
# unchanged.
#
# Stdin: PreToolUse JSON payload (see claude-code/src/utils/hooks.ts).
# Stdout: hookSpecificOutput JSON with updatedInput.command, or empty for
#         pass-through. Always exits 0.

set -eu

input=$(cat)

# Best-effort field extraction. We need: tool_name, session_id, tool_use_id,
# tool_input.command, tool_input.timeout. Prefer jq when available; fall back
# to a small Python helper (Python ships with macOS and most Linux distros).
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

# Sanitize: only allow safe characters in path components to keep $LOG safe.
case "$session_id$tool_use_id" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

log_dir="/tmp/cc-peek/$session_id"
log="$log_dir/$tool_use_id.log"
mkdir -p "$log_dir"

# Wrap the original command. `set -o pipefail` so the original exit code
# propagates through `tee`. Braces preserve operator precedence inside the
# original command. stderr is merged into stdout so peekers see both.
wrapped="set -o pipefail; { $command; } 2>&1 | tee $(printf '%q' "$log")"

# Emit the hookSpecificOutput payload. Build JSON via Python (or jq) to
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
