# Claude Code Feature Audit for cc.nvim Testing

Produced by auditing `~/src/claude-code/src` and cross-referencing with
cc.nvim's current `router.lua`, `output.lua`, `interactive.lua`, and
`session.lua`.

## Legend

- **Handled** = cc.nvim currently renders/handles this
- **Partial** = some handling but incomplete
- **Not handled** = message arrives but is silently dropped or no-op'd
- **N/A** = not relevant to cc.nvim (TUI-only or internal)

---

## 1. Top-Level Message Types

| Type | cc.nvim Status | Notes |
|---|---|---|
| `system` (init) | Handled | Extracts session_id, model, tools list |
| `system` (compact_boundary) | Handled | Renders "Context Compacted" notice |
| `system` (status: compacting) | Handled | Renders "Compacting context..." notice |
| `system` (post_turn_summary) | Not handled | Turn summary after each assistant turn |
| `system` (api_retry) | Handled | Renders "API retry" notice (via top-level `api_retry` type check) |
| `system` (session_state_changed) | Not handled | Session state transitions |
| `system` (files_persisted) | Not handled | File persistence events |
| `system` (elicitation_complete) | Not handled | MCP elicitation completed |
| `system` (local_command_output) | Not handled | Local command output |
| `stream_event` | Handled | Full streaming pipeline |
| `assistant` | Handled | Post-streaming reconciliation (no-op, UI already current) |
| `user` | Handled | Tool results from executed tools |
| `user_replay` | Not handled | User replay variant (seen during resume?) |
| `result` | Handled | Final cost/usage display |
| `control_request` (can_use_tool) | Handled | Permission prompts + interactive tools |
| `control_request` (elicitation) | Handled | MCP elicitation (URL + form modes) |
| `control_request` (other subtypes) | Not handled | interrupt, set_permission_mode, set_model, etc. |
| `tool_progress` | Handled | Elapsed time updates on running tools |
| `tool_use_summary` | Not handled | Commented "skip for now" |
| `prompt_suggestion` | Not handled | Suggested prompt completions |
| `auth_status` | Not handled | Auth status changes |
| `rate_limit` / `rate_limit_event` | Not handled | No-op in router |
| `hook_started` | Handled | Renders hook start notice |
| `hook_progress` | Not handled | Commented "usually noisy; skip" |
| `hook_response` | Handled | Renders hook completion with elapsed time |
| `task_started` | Handled | Renders sub-agent start notice |
| `task_progress` | Not handled | Commented "skip; tool_progress handles" |
| `task_notification` | Handled | Renders sub-agent completion |
| `streamlined_text` | Not handled | Optimized text format |
| `streamlined_tool_use_summary` | Not handled | Optimized tool summary format |

## 2. Stream Event Subtypes

| Event Type | cc.nvim Status | Notes |
|---|---|---|
| `message_start` | Handled | Begins assistant turn |
| `content_block_start` | Handled | Routes by block type (text/tool_use/thinking) |
| `content_block_delta` | Handled | Appends text deltas, accumulates tool input JSON |
| `content_block_stop` | Handled | Finalizes tool calls, renders tool headers |
| `message_delta` | Not handled | Contains stop_reason and usage delta |
| `message_stop` | Handled | Ends message |

## 3. Content Block Types

| Block Type | cc.nvim Status | Notes |
|---|---|---|
| `text` | Handled | Streamed text → output buffer |
| `tool_use` | Handled | Tool name + accumulated JSON input |
| `thinking` | Partial | Gated by `config.show_thinking`; renders when enabled |
| `redacted_thinking` | Not handled | Redacted thinking blocks |
| `server_tool_use` | Not handled | Server-side tools (web search) |

## 4. Tool Types (by rendering needs)

### File I/O Tools
| Tool | cc.nvim Rendering | Notes |
|---|---|---|
| `Read` | Handled | Summary line + result content at fold level 3 |
| `Edit` | Handled | Summary + inline unified diff via `diff.lua` |
| `Write` | Handled | Summary + all-add diff via `diff.lua:render_write` |
| `MultiEdit` | Handled | Summary + per-edit diffs via `diff.lua:render_multiedit` |
| `NotebookEdit` | Not handled | Jupyter notebook edits — likely renders as generic tool |

### Shell & Process
| Tool | cc.nvim Rendering | Notes |
|---|---|---|
| `Bash` | Handled | Summary + command at fold 2, stdout/stderr at fold 3 |
| `PowerShell` | Not handled | Windows-only; renders as generic tool |

### Search & Discovery
| Tool | cc.nvim Rendering | Notes |
|---|---|---|
| `Glob` | Handled | Summary + results at fold 3 |
| `Grep` | Handled | Summary + results at fold 3 |
| `WebSearch` | Not handled | Server-side tool; uses `server_tool_use` blocks |
| `WebFetch` | Not handled | Renders as generic tool |
| `ToolSearch` | Not handled | Deferred tool search; renders as generic tool |
| `LSP` | Not handled | LSP operations; renders as generic tool |

### Agent & Coordination
| Tool | cc.nvim Rendering | Notes |
|---|---|---|
| `Agent` | Partial | Task start/done notices; no inline sub-agent output |
| `SendMessage` | Not handled | In-process teammate messaging |
| `TaskCreate/Get/Update/List/Stop/Output` | Not handled | Task management tools |

### Planning & Interaction
| Tool | cc.nvim Rendering | Notes |
|---|---|---|
| `EnterPlanMode` | Handled | Auto-approve + notice + stores plan file path |
| `ExitPlanMode` | Handled | Float preview + Approve/Reject/Edit picker |
| `AskUserQuestion` | Handled | Single/multi select + free text via vim.ui |

### MCP & Integration
| Tool | cc.nvim Rendering | Notes |
|---|---|---|
| MCP tools (`mcp__*`) | Partial | Renders as generic tool_use; no MCP-specific UI |

### Other Tools
| Tool | cc.nvim Rendering | Notes |
|---|---|---|
| `Skill` | Not handled | Skill invocation; renders as generic tool |
| `TodoWrite` | Not handled | Renders as generic tool |
| `Config` | Not handled | Ant-only config tool |
| `EnterWorktree` / `ExitWorktree` | Not handled | Worktree isolation |
| `CronCreate/Delete/List` | Not handled | Scheduled tasks |
| `RemoteTrigger` | Not handled | Remote agent triggers |
| `Sleep` | Not handled | Delay tool |
| `Monitor` | Not handled | Background process monitoring |
| `PushNotification` | Not handled | Push notifications |

## 5. Interactive / Control Request Types

| Feature | cc.nvim Status | Notes |
|---|---|---|
| Permission prompt (can_use_tool) | Handled | Allow/Deny/Always Allow picker |
| MCP elicitation — URL mode | Handled | Opens browser via vim.ui.open |
| MCP elicitation — form mode | Handled | Property-by-property vim.ui.input |
| MCP elicitation — confirm/cancel | Handled | Accept/Cancel picker |
| EnterPlanMode | Handled | Auto-approve + notice |
| ExitPlanMode | Handled | Float + 3-way picker |
| AskUserQuestion — single select | Handled | vim.ui.select |
| AskUserQuestion — multi select | Handled | Iterative vim.ui.select |
| AskUserQuestion — free text | Handled | "Other (type)" → vim.ui.input |
| interrupt | Not handled | Could map to :CcStop |
| set_permission_mode | Not handled | Runtime permission mode change |
| set_model | Not handled | Runtime model switch |

## 6. Hook Event Types

| Event | cc.nvim Status | Notes |
|---|---|---|
| `hook_started` (PreToolUse) | Handled | Renders "⚙ Hook: <name> started" |
| `hook_response` (PostToolUse) | Handled | Renders "⚙ Hook: <name> done" with elapsed |
| `hook_progress` | Not handled | Skipped as noisy |
| Other hook types (SessionStart, SubagentStart, etc.) | Not handled | Only PreToolUse/PostToolUse hooks render |

## 7. Display Features

| Feature | cc.nvim Status | Notes |
|---|---|---|
| Streaming text append | Handled | Partial deltas via `_append_to_last_line` |
| Unified diffs (Edit) | Handled | `vim.diff()` histogram algorithm |
| All-add diffs (Write) | Handled | All lines prefixed with `+` |
| Multi-edit diffs | Handled | Per-edit sections with separators |
| Fold levels 0-3 | Handled | Progressive disclosure |
| Foldtext summaries | Handled | Role-aware with tool count and text preview |
| Carets (▾/▸) | Handled | Inline virt_text synced to fold state |
| Spinner | Handled | Braille animation on Agent header |
| Cost/usage bar | Handled | `── $X.XX │ Nk in │ N out ──` |
| Thinking blocks | Partial | Only when `show_thinking = true` |
| Highlight groups (14 CcXxx) | Handled | Regex-based syntax matches |
| Tool elapsed time | Handled | Updates via tool_progress messages |

---

## Proposed Feature Subset for Testing

### Tier 1 — Core (must test, already handled)
These are the bread-and-butter features that every session exercises:

1. **Text streaming** — message_start → content_block_delta (text) → message_stop
2. **Tool calls — Read** — summary + file content result
3. **Tool calls — Edit** — summary + unified diff rendering
4. **Tool calls — Write** — summary + all-add diff
5. **Tool calls — MultiEdit** — summary + per-edit diffs with separators
6. **Tool calls — Bash** — summary + command + stdout/stderr
7. **Tool calls — Glob/Grep** — summary + search results
8. **Fold levels 0/1/2/3** — progressive disclosure at each level
9. **Foldtext summaries** — role-aware text (User/Agent/Tool/Result)
10. **Carets (▾/▸)** — extmark sync with fold state
11. **Cost/usage display** — result message → cost bar rendering
12. **Highlight groups** — all 14 CcXxx groups resolve correctly
13. **Multi-turn conversations** — User/Agent alternation with multiple tools
14. **Permission prompts** — can_use_tool → Allow/Deny/Always Allow

### Tier 2 — Interactive (should test, already handled)
15. **AskUserQuestion — single select** — options picker
16. **AskUserQuestion — multi select** — iterative selection
17. **AskUserQuestion — free text** — "Other" escape hatch
18. **EnterPlanMode** — auto-approve + notice
19. **ExitPlanMode** — float preview + 3-way choice
20. **MCP elicitation — URL** — browser open flow
21. **MCP elicitation — form** — property input flow

### Tier 3 — System events (should test, already handled)
22. **System init** — session_id extraction, model info
23. **Compact boundary** — "Context Compacted" notice
24. **Compacting status** — "Compacting context..." notice
25. **API retry** — retry notice
26. **Hook started/response** — hook execution notices
27. **Sub-agent started/done** — task_started/task_notification rendering
28. **Spinner animation** — braille cycle on Agent header during streaming
29. **Tool elapsed time** — progressive time updates

### Tier 4 — Not yet handled (test to document current behavior, defer support)
30. **Thinking blocks** — verify show_thinking=true/false behavior
31. **WebSearch results** — server_tool_use blocks (currently renders as generic)
32. **MCP tool calls** — mcp__* prefix tools (currently renders as generic)
33. **Sub-agent inline output** — Agent tool with streaming task_progress

### Out of scope for v1 testing
- PowerShell (Windows-only)
- streamlined_* optimized formats
- Config tool (Ant-only)
- TeamCreate/TeamDelete (agent swarms, feature-gated)
- CronCreate/Delete/List, RemoteTrigger (scheduling, feature-gated)
- Sleep, Monitor, PushNotification (background/proactive features)
- NotebookEdit (niche)
- Worktree tools (niche)
