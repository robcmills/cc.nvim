#!/bin/bash
# Bidirectional fake claude for permission e2e tests.
#
# Emits: system/init, then a can_use_tool control_request (Bash, with
# permission_suggestions). Captures the first NDJSON line from stdin —
# expected to be the SDK's control_response — into $CC_TEST_RESPONSE_FILE.
# Then emits a `result` so cc renders "Session ended" and exits cleanly.
#
# Env (all optional, defaults shown):
#   CC_TEST_REQUEST_ID   — request_id for the can_use_tool request (default: test-perm-req-1)
#   CC_TEST_TOOL_NAME    — tool to ask about (default: Bash)
#   CC_TEST_OMIT_SUGGESTIONS=1 — omit permission_suggestions to exercise the fallback path
# Env (required):
#   CC_TEST_RESPONSE_FILE — absolute path; receives the captured control_response line

set -euo pipefail

REQUEST_ID="${CC_TEST_REQUEST_ID:-test-perm-req-1}"
TOOL_NAME="${CC_TEST_TOOL_NAME:-Bash}"
RESPONSE_FILE="${CC_TEST_RESPONSE_FILE:?CC_TEST_RESPONSE_FILE not set}"

# system/init — bootstraps session state.
echo '{"type":"system","subtype":"init","session_id":"fake-perm-session","model":"fake","tools":["Bash"],"slash_commands":[],"skills":[],"permissionMode":"default","cwd":"/tmp","apiKeySource":"none"}'

# can_use_tool control_request. The router dispatches this straight to the
# permission float without any prior tool_use streaming — that's fine because
# we're testing the response path, not the rendered "what command is this"
# preview.
if [[ "${CC_TEST_OMIT_SUGGESTIONS:-0}" == "1" ]]; then
  printf '{"type":"control_request","request_id":"%s","request":{"subtype":"can_use_tool","tool_name":"%s","input":{"command":"ls"},"tool_use_id":"tu-test"}}\n' \
    "$REQUEST_ID" "$TOOL_NAME"
else
  printf '{"type":"control_request","request_id":"%s","request":{"subtype":"can_use_tool","tool_name":"%s","input":{"command":"ls"},"tool_use_id":"tu-test","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"%s","ruleContent":"ls:*"}],"behavior":"allow","destination":"localSettings"}]}}\n' \
    "$REQUEST_ID" "$TOOL_NAME" "$TOOL_NAME"
fi

# Block on stdin for the SDK's control_response. `head -n 1` reads exactly one
# line and writes it to the response file; the remainder of stdin is ignored.
head -n 1 > "$RESPONSE_FILE"

# Wrap up with a `result` so cc shows "Session ended".
echo '{"type":"result","subtype":"success","result":"done","duration_ms":1,"duration_api_ms":1,"is_error":false,"num_turns":0,"session_id":"fake-perm-session","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}'
