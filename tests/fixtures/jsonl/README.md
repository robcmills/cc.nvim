# JSONL Fixtures

Curated from real Claude Code sessions. These test the **resume/replay
rendering path** (`:CcResume` / `history.lua`).

## Format

Stored session JSONL — one JSON object per line. Message types present:
- `user` — user prompt (string content) or tool results (content array with `tool_result` blocks)
- `assistant` — assistant reply with `text`, `tool_use`, `thinking` content blocks
- `system` — system events (compact_boundary, etc.)
- `attachment`, `queue-operation`, `file-history-snapshot` — metadata (skipped by renderer)

**Not present in stored JSONL** (streaming-only, need NDJSON fixtures):
- `stream_event` (partial deltas, content_block_start/stop)
- `result` (cost/usage)
- `hook_started` / `hook_response`
- `task_started` / `task_notification`
- `tool_progress`
- `control_request` (permission prompts)

## Fixture Inventory

| Fixture | Feature | Source Session |
|---|---|---|
| `simple_text.jsonl` | Minimal user → assistant text reply | cc.nvim 3ab7ac43 |
| `tool_read.jsonl` | Read tool call + file content result | cc.nvim aedd9f2c |
| `tool_edit.jsonl` | Edit tool call (old_string/new_string for diff) | cc.nvim aedd9f2c |
| `tool_write.jsonl` | Write tool call (full file content) | cc.nvim aedd9f2c |
| `tool_bash.jsonl` | Bash tool call + stdout result | cc.nvim aedd9f2c |
| `tool_grep.jsonl` | Grep tool call + search results | cc.nvim aedd9f2c |
| `multi_turn.jsonl` | 3+ turns with mixed tools (Read, Grep, thinking) | cc.nvim aedd9f2c |
| `ask_user_question.jsonl` | AskUserQuestion tool with options | cc.nvim aedd9f2c |
| `enter_plan_mode.jsonl` | EnterPlanMode tool call | openspace2 6530f0e3 |
| `plan_mode.jsonl` | ExitPlanMode tool with plan content | cc.nvim cc9e5807 |
| `compact_boundary.jsonl` | system compact_boundary event | openclaw ae753b1b |
| `subagent.jsonl` | Agent tool (sub-agent spawn + result) | cc.nvim aedd9f2c |
| `mcp_chrome.jsonl` | MCP chrome tabs_context_mcp tool | openspace 94b201c0 |
| `mcp_atlassian.jsonl` | MCP Atlassian getAccessibleResources | flaky-tests 4d616ab7 |
| `mcp_slack.jsonl` | MCP Slack read_channel tool | dead-code 16c55252 |
| `websearch.jsonl` | WebSearch tool call | money 496b5bee |
| `skill.jsonl` | Skill tool invocation | flaky-tests 4d616ab7 |
| `thinking.jsonl` | (not extracted — thinking is in most assistant messages) | — |

## Notes

- Large tool results and file contents are truncated for fixture size
- Thinking blocks are truncated to ~200 chars (content not important for rendering tests)
- No sensitive credentials in these fixtures (only tool names, file paths, code snippets)
- `thinking.jsonl` not needed as a separate fixture — thinking blocks appear in most
  assistant messages in `multi_turn.jsonl` and others
