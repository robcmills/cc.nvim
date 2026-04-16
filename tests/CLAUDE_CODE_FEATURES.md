# Claude Code Complete Feature Set

Raw inventory of all Claude Code features relevant to a rendering client,
audited from `~/src/claude-code/src` (2026-04-15).

---

## Top-Level NDJSON Message Types

Every line on stdout is a JSON object with a `type` field:

| Type | Description |
|---|---|
| `system` | System messages with `subtype` field (see below) |
| `stream_event` | Streaming partial assistant content with `event` field |
| `assistant` | Post-streaming reconciliation (full message after stream completes) |
| `user` | User turn — carries `tool_result` blocks after tool execution |
| `user_replay` | User replay variant (resume/history contexts) |
| `result` | Final turn result with cost, usage, duration |
| `control_request` | Request requiring client response (permissions, config, elicitation) |
| `tool_progress` | Intermediate progress for running tools (elapsed time) |
| `tool_use_summary` | Summary of completed tool call |
| `prompt_suggestion` | Suggested prompt completion |
| `auth_status` | Authentication status change |
| `rate_limit` / `rate_limit_event` | Rate limit notifications |
| `api_retry` | API retry notification |
| `hook_started` | Hook execution started |
| `hook_progress` | Hook execution progress |
| `hook_response` | Hook execution result |
| `task_started` | Sub-agent task started |
| `task_progress` | Sub-agent progress update |
| `task_notification` | Sub-agent completion/status notification |
| `streamlined_text` | Optimized text message format |
| `streamlined_tool_use_summary` | Optimized tool summary format |

---

## System Message Subtypes

Messages with `type: 'system'` have a `subtype` field:

| Subtype | Description |
|---|---|
| `init` | Session initialization — session_id, model, tools, capabilities |
| `compact_boundary` | Context compaction boundary marker |
| `status` | Status updates (e.g., `status: 'compacting'`) |
| `post_turn_summary` | Summary after each assistant turn |
| `api_retry` | API retry notification |
| `local_command_output` | Local command output |
| `hook_started` | Hook execution started |
| `hook_progress` | Hook execution progress |
| `hook_response` | Hook execution result |
| `task_notification` | Task-related notification |
| `task_started` | Task started |
| `task_progress` | Task progress update |
| `session_state_changed` | Session state transition |
| `files_persisted` | File persistence event |
| `elicitation_complete` | MCP elicitation flow completed |

---

## Stream Event Types

Messages with `type: 'stream_event'` carry an `event` object:

| event.type | Description |
|---|---|
| `message_start` | Streaming begins; `event.message` has message ID |
| `content_block_start` | Content block begins; `event.content_block` has type + metadata |
| `content_block_delta` | Content chunk; `event.delta` has type-specific data |
| `content_block_stop` | Content block completes |
| `message_delta` | Message-level update (stop_reason, usage delta) |
| `message_stop` | Streaming complete |

---

## Content Block Types

Within `content_block_start`, the `content_block.type` field:

| Type | Description |
|---|---|
| `text` | Text content; deltas carry `delta.text` strings |
| `tool_use` | Tool call; `content_block.id`, `content_block.name`; deltas carry `delta.partial_json` |
| `thinking` | Extended thinking; deltas carry `delta.thinking` text |
| `redacted_thinking` | Redacted thinking block (no content exposed) |
| `server_tool_use` | Server-side tool (e.g., web search); executed on API side |

---

## Tool Types (Complete List)

Source: `~/src/claude-code/src/constants/tools.ts` and tool directories.

### Core File Operations
| Tool Name | Description | Input Fields |
|---|---|---|
| `Read` | Read file contents | `file_path`, `offset?`, `limit?`, `pages?` |
| `Edit` | Replace text in file | `file_path`, `old_string`, `new_string`, `replace_all?` |
| `Write` | Write/overwrite file | `file_path`, `content` (alias: `file_contents`) |
| `MultiEdit` | Multiple edits to one file | `file_path`, `edits[]` (each: old_string, new_string) |
| `NotebookEdit` | Edit Jupyter notebook | `notebook_path`, `cell_id?`, `new_source`, `cell_type?`, `edit_mode` |

### Shell & Execution
| Tool Name | Description | Input Fields |
|---|---|---|
| `Bash` | Execute shell command | `command`, `description?`, `run_in_background?`, `timeout?` |
| `PowerShell` | Windows shell | Same as Bash |
| `REPL` | Interactive REPL | `command` |
| `Sleep` | Delay execution | `delaySeconds` |
| `Monitor` | Stream background process | `command`, `description`, `timeout_ms`, `persistent?` |

### Search & Discovery
| Tool Name | Description | Input Fields |
|---|---|---|
| `Glob` | File pattern matching | `pattern`, `path?` |
| `Grep` | Content search (ripgrep) | `pattern`, `path?`, `glob?`, `type?`, `output_mode?`, `context?`, `head_limit?`, `-A?`, `-B?`, `-C?`, `-i?`, `-n?`, `multiline?`, `offset?` |
| `WebSearch` | Web search (server-side) | `query`, `allowed_domains?`, `blocked_domains?` |
| `WebFetch` | Fetch URL content | `url`, `prompt` |
| `ToolSearch` | Search available tools | `query`, `max_results?` |
| `LSP` | Language Server Protocol | `operation`, `filePath`, `line`, `character` |

### Agent & Coordination
| Tool Name | Description | Input Fields |
|---|---|---|
| `Agent` | Spawn sub-agent | `description`, `prompt`, `subagent_type?`, `model?`, `run_in_background?`, `name?`, `team_name?`, `mode?`, `isolation?`, `cwd?` |
| `SendMessage` | Message teammate | `to`, `message` |
| `TaskOutput` | Emit structured output | (coordinator-only) |
| `TeamCreate` | Create agent team | (feature-gated) |
| `TeamDelete` | Delete agent team | (feature-gated) |

### Task Management
| Tool Name | Description | Input Fields |
|---|---|---|
| `TaskCreate` | Create task | `subject`, `description`, `activeForm?`, `metadata?` |
| `TaskGet` | Get task details | `taskId` |
| `TaskUpdate` | Update task | `taskId`, `status?`, `subject?`, `description?`, `owner?`, `metadata?`, `addBlocks?`, `addBlockedBy?` |
| `TaskList` | List all tasks | (none) |
| `TaskStop` | Stop running task | `taskId` |

### Planning & Interaction
| Tool Name | Description | Input Fields |
|---|---|---|
| `EnterPlanMode` | Enter plan mode | `plan_file_path?` |
| `ExitPlanMode` | Exit plan mode | `plan?` (text), `plan_file_path?`, `allowedPrompts?` |
| `AskUserQuestion` | Ask user a question | `question`, `options?[]`, `multiSelect?` |
| `SendUserMessage` | Send message to user | `message` |

### MCP & Integration
| Tool Name | Description | Input Fields |
|---|---|---|
| `mcp__<server>__<tool>` | MCP tool (dynamic) | Defined by MCP server schema |
| `ListMcpResourcesTool` | List MCP resources | (none) |
| `ReadMcpResourceTool` | Read MCP resource | `server`, `uri` |
| `McpAuth` | MCP auth handler | (internal) |

### Worktree Isolation
| Tool Name | Description | Input Fields |
|---|---|---|
| `EnterWorktree` | Create git worktree | `name?`, `path?` |
| `ExitWorktree` | Leave git worktree | `action: 'keep'|'remove'`, `discard_changes?` |

### Scheduling & Background
| Tool Name | Description | Input Fields |
|---|---|---|
| `CronCreate` | Create cron job | (feature-gated) |
| `CronDelete` | Delete cron job | (feature-gated) |
| `CronList` | List cron jobs | (feature-gated) |
| `RemoteTrigger` | Remote agent trigger | (feature-gated) |
| `PushNotification` | Push notification | `message`, `status` |

### Other
| Tool Name | Description | Input Fields |
|---|---|---|
| `Skill` | Invoke skill | `command`, `args?` |
| `TodoWrite` | Add TODO comment | `file_path`, `line_number`, `text` |
| `Config` | Manage settings | (Ant-only) |
| `Workflow` | Workflow tool | (feature-gated) |

---

## Control Request Subtypes

Messages with `type: 'control_request'` have `request.subtype`:

| Subtype | Description | Requires Response |
|---|---|---|
| `can_use_tool` | Permission to execute a tool | Yes — allow/deny |
| `elicitation` | MCP credential/input request | Yes — accept/cancel + content |
| `interrupt` | Interrupt current operation | Yes |
| `initialize` | SDK session initialization | Yes |
| `set_permission_mode` | Change permission mode at runtime | Yes |
| `set_model` | Switch model at runtime | Yes |
| `set_max_thinking_tokens` | Configure thinking budget | Yes |
| `mcp_status` | Query MCP server status | Yes |
| `get_context_usage` | Get context window usage | Yes |
| `hook_callback` | Deliver hook callback | Yes |
| `mcp_message` | Send JSON-RPC to MCP server | Yes |
| `rewind_files` | Rewind file changes | Yes |
| `cancel_async_message` | Cancel pending async | Yes |
| `seed_read_state` | Seed file read cache | Yes |
| `mcp_set_servers` | Replace MCP server set | Yes |
| `reload_plugins` | Reload plugins from disk | Yes |
| `mcp_reconnect` | Reconnect MCP server | Yes |
| `mcp_toggle` | Enable/disable MCP server | Yes |
| `stop_task` | Stop a running task | Yes |
| `apply_flag_settings` | Merge flag settings | Yes |
| `get_settings` | Query effective settings | Yes |

---

## Hook Event Types

Hook events flow as top-level messages (`hook_started`, `hook_progress`,
`hook_response`) and internally have a `hook_event_name`:

| Hook Event | Description | Trigger |
|---|---|---|
| `PreToolUse` | Before tool execution | Every tool call |
| `PostToolUse` | After tool succeeds | Every successful tool |
| `PostToolUseFailure` | After tool fails/interrupts | Tool error/SIGINT |
| `PermissionRequest` | Permission check needed | Restricted tools |
| `PermissionDenied` | Permission denied by policy | Policy violation |
| `Notification` | General notification | Various |
| `UserPromptSubmit` | User submitted prompt | User sends message |
| `SessionStart` | Session beginning | startup/resume/clear/compact |
| `SessionEnd` | Session ending | Exit/close |
| `Stop` | Stop command issued | :CcStop / SIGINT |
| `StopFailure` | Stop operation failed | Error during stop |
| `Setup` | Setup hook | init/maintenance |
| `TeammateIdle` | Teammate idle threshold | Multi-agent idle |
| `TaskCreated` | Async task created | Agent tool (background) |
| `TaskCompleted` | Async task completed | Sub-agent done |
| `SubagentStart` | Subagent spawned | Agent tool |
| `SubagentStop` | Subagent stopped | Agent done/killed |
| `PreCompact` | Before compaction | Context approaching limit |
| `PostCompact` | After compaction | Context compacted |
| `Elicitation` | MCP elicitation event | MCP auth flow |
| `ElicitationResult` | Elicitation result | MCP auth complete |
| `ConfigChange` | Configuration changed | Settings update |
| `WorktreeCreate` | Worktree created | EnterWorktree |
| `WorktreeRemove` | Worktree removed | ExitWorktree |
| `InstructionsLoaded` | Instructions file loaded | CLAUDE.md found |
| `CwdChanged` | Working directory changed | cd or worktree |
| `FileChanged` | Watched file changed | File watcher |

---

## Permission Model

### Permission Modes
| Mode | Description |
|---|---|
| `default` | Ask for permission on restricted tools |
| `auto` | Auto-allow most tools |
| `acceptEdits` | Auto-allow reads, ask for writes |
| `plan` | Block edits until plan approved |
| `bypassPermissions` | Allow everything (dangerous) |

### Tool Permission Categories
- **Always safe (no prompt):** Read, Glob, Grep, ToolSearch, TaskList, TaskGet
- **Destructive (require permission):** Edit, Write, NotebookEdit, Bash, Agent (async)
- **Interactive (special UI):** AskUserQuestion, EnterPlanMode, ExitPlanMode
- **Deferred (lazy-loaded):** TaskCreate, TaskGet, NotebookEdit, ToolSearch

---

## Result Message Shape

The `result` message carries final turn data:

```json
{
  "type": "result",
  "cost_usd": 0.05,
  "duration_ms": 12345,
  "duration_api_ms": 10000,
  "input_tokens": 12000,
  "output_tokens": 550,
  "num_turns": 1,
  "session_id": "...",
  "model": "claude-opus-4-6",
  "is_error": false,
  "total_cost_usd": 1.23,
  "total_input_tokens": 50000,
  "total_output_tokens": 5000
}
```

---

## Tool Output Shapes (Rendering-Relevant)

### Edit tool output
```json
{
  "filePath": "src/auth.ts",
  "oldString": "const ttl = '1h'",
  "newString": "const ttl = '24h'",
  "structuredPatch": [
    { "oldStart": 10, "oldLines": 3, "newStart": 10, "newLines": 3, "lines": [...] }
  ],
  "gitDiff": "..."
}
```

### Bash tool output
Plain text stdout/stderr with exit code.
`isSearchOrReadCommand()` returns `{isSearch, isRead, isList}` for UI collapsing.

### Agent tool output
```json
{
  "status": "completed" | "async_launched",
  "result": "...",
  "agentId": "...",
  "prompt": "..."
}
```
Progress via `tool_progress` with `AgentToolProgress` type.

### WebSearch output
Interleaves text commentary + structured `SearchResult` objects.
Uses `server_tool_use` + `web_search_tool_result` content blocks (not regular tool_use).
