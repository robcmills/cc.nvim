# Codex CLI Support Plan

## Summary

Adding Codex CLI support is feasible, but it should be implemented as a provider integration rather than by extending the existing Claude-specific router with Codex message types.

The recommended backend is `codex app-server`, not `codex exec --json`. App-server is intended for rich clients and provides persistent threads, streamed turns, approvals, interruption, history, naming, usage, and typed tool events over newline-delimited JSON-RPC. `codex exec` is designed primarily for one-shot automation and CI workflows.

Useful upstream references:

- [Codex app-server documentation](https://developers.openai.com/codex/app-server)
- [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive)

## Goals

- Preserve all existing Claude behavior and configuration.
- Add `codex` as a selectable provider.
- Reuse the current Neovim buffers, folding, rendering, statusline, and prompt experience.
- Keep provider wire protocols out of shared UI code.
- Avoid new runtime dependencies.
- Make unsupported or provider-specific features explicit rather than approximating them incorrectly.

## Non-goals

- Reimplement Codex authentication, model routing, MCP internals, or sandboxing.
- Force exact feature parity where the two CLIs expose different concepts.
- Translate Codex events into fake Anthropic protocol messages.
- Make `codex exec --json` behave like a persistent interactive transport.

## Proposed architecture

Introduce an internal provider interface with operations along these lines:

```lua
provider:start()
provider:new_session()
provider:resume(id)
provider:send(text)
provider:interrupt()
provider:respond(request_id, decision)
provider:list_sessions(opts)
provider:read_session(id)
provider:rename(id, name)
provider:close()
provider:is_alive()
```

Move the existing Claude implementation behind `lua/cc/providers/claude.lua` and add `lua/cc/providers/codex.lua`. Shared process plumbing can remain separate where useful, but provider-specific arguments, requests, responses, and lifecycle rules should live inside the providers.

Providers should emit a normalized internal event model rather than exposing their native messages to the shared renderer:

```text
session_started
session_updated
turn_started
assistant_started
assistant_delta
assistant_completed
reasoning_delta
plan_updated
tool_started
tool_output
tool_completed
approval_requested
approval_resolved
usage_updated
turn_completed
notice
error
```

The normalized events do not need to be a public API initially. They only need enough structure to keep provider protocol details out of `router.lua`, `session.lua`, and `output.lua`.

## Why a provider boundary is necessary

The current implementation is coupled to Claude Code in several places:

- `process.lua` constructs Claude `stream-json` arguments and sends Claude `control_request` messages.
- `router.lua` understands Anthropic content blocks, Claude tool results, hook events, and Claude permission requests.
- `session.lua` derives state and usage from Claude `system`, `stream_event`, and `result` messages.
- `history.lua` reads `~/.claude/projects` JSONL files directly.
- `init.lua` writes Claude user messages directly and duplicates process construction across new, clear, and resume paths.
- Permission modes, effort handling, version checks, auto-rename, and `CcPeek` contain Claude-specific behavior.

Keeping these assumptions in the shared path would make Codex support difficult to test and fragile as either protocol changes.

## Codex app-server integration

### Transport and lifecycle

The Codex provider should:

1. Spawn `codex app-server` using `vim.uv.spawn()` with stdin, stdout, and stderr pipes.
2. Send the required `initialize` request with cc.nvim client metadata.
3. Send the `initialized` notification after initialization succeeds.
4. Call `thread/start` for a new conversation or `thread/resume` for an existing one.
5. Store the returned thread ID and current turn ID.
6. Call `turn/start` when the user submits a prompt.
7. Read JSON-RPC responses, notifications, and server-initiated requests continuously.
8. Call `turn/interrupt` to stop an active turn.
9. Close the app-server subprocess during instance teardown.

The existing NDJSON line parser can likely be reused. A JSON-RPC layer must add monotonically increasing request IDs, pending-callback correlation, error handling, and server-request responses.

### Event translation

Initial mappings should include:

| Codex event or item | cc.nvim normalized behavior |
|---|---|
| `thread/started` or `thread/start` result | `session_started` |
| `turn/started` | `turn_started` |
| `item/agentMessage/delta` | `assistant_delta` |
| completed `agentMessage` item | authoritative assistant message completion |
| reasoning summary deltas | `reasoning_delta` |
| `turn/plan/updated` and plan items | `plan_updated` |
| `commandExecution` | shell-command tool record |
| command output deltas | streamed tool output |
| `fileChange` | edit/write tool record with supplied diff |
| `mcpToolCall` | MCP tool record |
| `webSearch` | web-search tool record |
| `collabToolCall` | subagent/collaboration tool record |
| `contextCompaction` | context-compaction notice |
| `thread/tokenUsage/updated` | `usage_updated` |
| `turn/completed` | `turn_completed` |
| warning or error notification | notice or error rendering |

Treat `item/completed` as authoritative when Codex provides both deltas and a final item. This prevents partial-stream reconciliation errors.

### Approvals and user input

Reuse the existing permission-window presentation where it fits, but keep provider response encoding separate.

Codex approval handlers are needed for at least:

- Command execution approval.
- File-change approval.
- Network approval context.
- Tool-driven user input.
- Permission grants requested by the built-in permissions tool.

The provider must preserve the JSON-RPC request ID and respond with the correct Codex decision value. Available choices can differ by request, so the UI should accept provider-supplied choices rather than assume Claude's allow-once/allow-always model.

Concurrent approval requests should be keyed by request ID, thread ID, turn ID, and item ID. Teardown and interruption must dismiss or invalidate pending prompts safely.

## Shared rendering changes

The current output renderer should remain the visual foundation. Add provider-neutral entry points where the existing functions assume Anthropic content blocks.

Suggested mappings:

- Codex `commandExecution` renders like a Bash tool call, including command, working directory, status, duration, exit code, and folded output.
- Codex `fileChange` renders as an edit tool with the app-server-provided diff.
- MCP calls use the existing configurable tool icon and input formatting paths.
- Web searches and collaboration calls get explicit default icons and summaries.
- Reasoning summaries use the existing thinking disclosure level when enabled.
- Plans render as plan content and status updates without pretending that Claude plan mode is active.

Tool IDs must remain provider-opaque strings. Shared rendering should not infer semantics from their format.

## Session state and statusline

Make session fields capability-aware:

- Session or thread ID: supported.
- Model: supported.
- Turn activity and interruption: supported.
- Input/output and context usage: populate from Codex usage events where available.
- Cost in USD: optional; hide or leave unset if the provider does not report it.
- Permission state: display Codex approval and sandbox policy terminology rather than Claude permission-mode names.
- CLI version: probe the selected provider binary.
- Effort: map to Codex reasoning effort when configured or reported.
- Remote-control state: replace with a provider-neutral pending-interaction state if appropriate.

The statusline formatter should continue receiving a stable table, with provider-specific or unavailable fields documented as optional. Add a `provider` field so custom formatters can branch deliberately.

## History, resume, and naming

Do not parse Codex rollout files directly for the primary implementation. Use app-server APIs:

- `thread/list` for the history picker, filtered by cwd where appropriate.
- `thread/read` with turns for pre-rendering stored history.
- `thread/resume` to continue a thread.
- `thread/name/set` for rename support.

Refactor the current history picker to consume provider-neutral history entries:

```lua
{
  id = string,
  name = string?,
  preview = string?,
  cwd = string?,
  created_at = number?,
  updated_at = number?,
  provider = 'claude' | 'codex',
}
```

Claude can continue using its existing local JSONL reader behind its provider implementation.

Codex history rendering should translate stored thread items into the same normalized records used for live events. This avoids maintaining separate live and historical renderers for every Codex item type.

## Configuration

Preserve current options and introduce a provider selector plus provider-specific configuration. One possible shape:

```lua
require('cc').setup({
  provider = 'claude',

  providers = {
    claude = {
      cmd = 'claude',
      permission_mode = nil,
      model = nil,
      extra_args = {},
    },
    codex = {
      cmd = 'codex',
      model = nil,
      approval_policy = nil,
      sandbox = nil,
      effort = nil,
      extra_args = {},
    },
  },
})
```

For backward compatibility:

- Existing `claude_cmd`, `permission_mode`, `model`, and `extra_args` values should continue configuring Claude.
- `provider` should default to `claude` for the first release.
- Avoid silently applying Claude permission modes or CLI arguments to Codex.
- Validate provider-specific options and report actionable health-check errors.

Provider selection can initially be global. Per-instance provider selection can be added later if there is a clear UX for commands, history, and buffer naming.

## Provider-specific features

Some features should remain explicitly provider-specific:

- `CcPeek` and the installed Claude `PreToolUse` hook remain Claude-only unless Codex gains an equivalent need and mechanism.
- Claude plan-mode tools and Codex plan items should not be treated as identical protocols.
- Claude slash-command discovery does not automatically apply to Codex.
- Claude permission cycling must be replaced or disabled for Codex until a sensible sandbox/approval-policy UX is defined.
- Claude auto-rename should not spawn Claude for Codex sessions. Prefer `thread/name/set`, optionally using an agent-generated title only if that behavior is deliberately designed.
- Claude latest-version lookup against the Anthropic npm package must not run for Codex.

Commands that are unavailable for the active provider should explain why rather than fail silently.

## Refactoring prerequisites

Before adding Codex behavior, reduce duplication in `init.lua`:

1. Centralize provider creation and callback wiring.
2. Centralize new-session, clear-session, and resume lifecycle handling.
3. Change prompt submission from writing a Claude message directly to calling `provider:send(text)`.
4. Change interruption to call `provider:interrupt()`.
5. Route history, rename, and capability checks through the selected provider.
6. Keep buffer creation, output rendering, prompt handling, window management, and instance teardown shared.

This refactor should preserve existing Claude fixtures and tests before any Codex implementation is introduced.

## Testing strategy

### Provider contract tests

Create shared tests that both providers must satisfy:

- Start and close lifecycle.
- Session ID propagation.
- Prompt submission.
- Turn-active state transitions.
- Assistant text streaming.
- Tool lifecycle.
- Interruption.
- Errors and subprocess exit.
- Pending request cleanup.

### Codex fixtures

Add captured or schema-derived fixtures covering:

- Initialization and thread start.
- Simple assistant response.
- Multi-delta response reconciliation.
- Command execution with streamed output.
- Successful and failed command completion.
- File change with diff.
- Command approval allow, session allow, decline, and cancel.
- File-change approval.
- Network approval context.
- MCP call.
- Web search.
- Reasoning summary and plan updates.
- Token usage.
- Context compaction.
- Turn interruption.
- Failed turn and JSON-RPC error.
- History list, read, resume, and rename.
- Multiple concurrent or sequential server requests.

Use `codex app-server generate-json-schema` from the installed CLI to validate assumptions and help keep fixtures aligned with the tested Codex version.

### Compatibility

- Add a minimum supported Codex version after verifying the first complete implementation.
- Probe `codex --version` in `:checkhealth cc` when Codex is selected.
- Report missing `app-server` support clearly.
- Test unknown event and item types as safe no-ops or generic tool/notice records.
- Avoid enabling experimental app-server capabilities unless a required feature has no stable equivalent.

## Delivery stages

### Stage 1: Provider extraction

- Add the provider interface and capability model.
- Move current Claude process and routing behavior behind the Claude provider.
- Centralize instance/provider construction.
- Route send, interrupt, resume, history, and rename through provider methods.
- Preserve all current behavior and keep the default provider as Claude.
- Add provider-contract tests around the existing Claude implementation.

Expected result: no visible feature changes, but Codex can be added without contaminating shared UI code.

### Stage 2: Codex MVP

- Add Codex configuration and health checks.
- Implement app-server spawn, initialization, request correlation, and teardown.
- Implement thread start/resume and turn start/interrupt.
- Render assistant text, command execution, file changes, basic MCP calls, errors, and turn completion.
- Add Codex fixtures and focused unit tests.
- Document intentionally unsupported commands and fields.

Expected result: reliable new and resumed Codex conversations with useful progressive output and interruption.

### Stage 3: Interactive and history parity

- Implement command, file, network, and permissions approval flows.
- Implement tool-driven user input.
- Integrate `thread/list`, `thread/read`, and `thread/name/set`.
- Populate usage, model, effort, and provider-aware statusline fields.
- Add reasoning, plan, collaboration, web-search, and compaction rendering.
- Add end-to-end tests for viewport behavior and approval timing.

Expected result: a usable beta suitable for normal Codex CLI work from cc.nvim.

### Stage 4: Polish and compatibility

- Improve provider-specific tool summaries, icons, and folds.
- Add configuration migration guidance and complete README coverage.
- Establish the supported Codex version range.
- Add graceful handling for protocol additions and capability differences.
- Evaluate optional per-instance provider selection.
- Audit memory cleanup, stale callbacks, pending approvals, and multi-session behavior.

## Rough effort

- MVP with new sessions, text streaming, basic command/file rendering, sending, and interruption: **3–5 focused days**.
- Usable beta with approvals, usage, history/resume, rename, health checks, fixtures, and documentation: **1–2 weeks**.
- Near-parity and polish, including broader tool coverage and compatibility testing: **2–4 weeks**.

The largest risks are not process spawning or JSON parsing. They are defining a clean provider-neutral event model, adapting the current Claude-specific history and permission paths, and keeping both providers well tested as their CLIs evolve.

## Initial implementation checklist

- [x] Define provider interface and capabilities. (`lua/cc/providers/init.lua`)
- [x] Add normalized event types. (Implemented as provider-neutral renderer
      entry points — `Output:render_*`, `on_content_block_*`, session fields —
      rather than a named event enum; providers translate wire messages into
      these calls, which satisfies the goal of keeping protocol details out
      of `router.lua`/`session.lua`/`output.lua`.)
- [x] Centralize provider construction in `init.lua`. (`attach_provider`)
- [x] Move Claude transport behind the provider interface. (`providers/claude.lua`)
- [x] Keep the full Claude test suite passing.
- [x] Add `provider = 'codex'` configuration.
- [x] Add Codex health/version probing. (`:checkhealth cc` checks binary,
      version, app-server availability, option validity, auth.)
- [x] Implement JSON-RPC request correlation.
- [x] Implement app-server initialization.
- [x] Implement thread start, resume, send, and interrupt.
- [x] Translate agent message and turn events.
- [x] Translate command and file-change items.
- [x] Implement approval responses. (Command + file-change, v2 and legacy
      shapes; tool/requestUserInput via vim.ui; permissions-profile and MCP
      elicitation requests are refused with a JSON-RPC error and a notice.)
- [x] Integrate Codex history and rename APIs. (thread/list via a transient
      headless client; thread/resume replay; thread/name/set for /rename.)
- [x] Add usage and provider-aware statusline behavior. (`state.provider`,
      per-provider CLI version probe, approval/sandbox mode string.)
- [x] Add fixtures, unit tests, and end-to-end tests. (Captured live fixture,
      protocol-level specs with a stubbed transport, subprocess integration
      specs against `tests/fixtures/fake_codex.sh`. Viewport-timing e2e specs
      for codex not yet added.)
- [x] Document provider-specific features and limitations. (README "Codex CLI
      support" section; CLAUDE.md architecture notes.)

