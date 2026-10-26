-- Dispatches SDK NDJSON messages to session (state) and output (render).

local ErrorNotice = require('cc.output.error_notice')
local Config = require('cc.config')

local M = {}

---@class cc.Router
---@field session cc.Session
---@field output cc.Output
---@field process cc.Process?
---@field instance cc.Instance?
---@field open_prompts table<string, cc.PendingPermission|{ tool_name: string, dismiss: fun() }>
---@field on_session_id fun(session_id: string)?
---@field interrupted_result_pending boolean true after an acknowledged interrupt until Claude's optional trailing result
---@field remote_control_failure string? detail of the last bridge_state failure, so the CLI's matching control_response error is not shown twice
---@field rate_limit_status string? status of the last rendered rate_limit_event
---@field rate_limit_key string? dedupe key of the last rendered rate_limit_event
---@field last_error_text string? error notice shown for the in-flight turn, so its `result` echo is not repeated
local Router = {}
Router.__index = Router

---@param opts { session: cc.Session, output: cc.Output, process: cc.Process?, instance: cc.Instance?, on_session_id: fun(session_id: string)? }
function M.new(opts)
  return setmetatable({
    session = opts.session,
    output = opts.output,
    process = opts.process,
    instance = opts.instance,
    open_prompts = {},
    on_session_id = opts.on_session_id,
    interrupted_result_pending = false,
  }, Router)
end

local function refresh_statusline(self)
  if self.instance then
    require('cc.statusline_spinner').sync(self.instance)
    require('cc.statusline').refresh(self.instance)
  end
end

local function result_text(content)
  if type(content) == 'string' then return content end
  if type(content) ~= 'table' then return '' end
  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == 'string' then
      table.insert(parts, block)
    elseif type(block) == 'table' and type(block.text) == 'string' then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts, '\n')
end

local function launched_task_id(msg, block)
  local result = msg.tool_use_result or msg.toolUseResult
  if type(result) == 'table' then
    local id = result.backgroundTaskId or result.background_task_id
      or result.agentId or result.agent_id
    if type(id) == 'string' and id ~= '' then return id end
  end
  local text = result_text(block.content)
  return text:match('background with ID:%s*([^%s%.]+)')
    or text:match('agentId:%s*([^%s%(]+)')
end

--- The CLI closes an aborted turn with a synthetic user message whose only
--- content is the text "[Request interrupted by user]" (or "... for tool
--- use]"). Both the stdin interrupt and a claude.ai interrupt abort with the
--- same reason and emit it; a permission denial does not.
---@param content table user message content blocks
---@return boolean
local function is_interrupt_marker(content)
  local text
  for _, block in ipairs(content) do
    if type(block) ~= 'table' or block.type ~= 'text' then return false end
    text = text or block.text
  end
  return type(text) == 'string' and text:find('^%[Request interrupted by user') ~= nil
end

---@param msg table
---@return boolean changed
function Router:_handle_task_notification(msg)
  local status = msg.status
  if status == 'running' or status == 'in_progress' or status == 'pending' then
    return false
  end
  local tool_use_id = msg.tool_use_id or msg.toolUseId
  local task_id = msg.task_id or msg.taskId or msg.agent_id or msg.agentId
  return self.session:finish_background_task(tool_use_id, task_id)
end

function Router:set_process(process)
  self.process = process
end

---@param msg table SDK NDJSON message
function Router:dispatch(msg)
  -- Every provider message is live conversation activity, even when it only
  -- updates rendered output or provider state rather than the session model.
  self.session:touch()
  local t = msg.type
  -- Messages from inside a subagent carry the parent Agent call's id. They
  -- render nested under that tool block and never touch top-level turn state.
  local parent_id = msg.parent_tool_use_id
  if type(parent_id) == 'string' and parent_id ~= '' then
    self:_handle_subagent_message(parent_id, msg)
    return
  end
  local before_turn_active = self.session.turn_active
  local background_changed = false
  if t == 'system' then
    self:_handle_system(msg)
  elseif t == 'stream_event' then
    self:_handle_stream_event(msg)
  elseif t == 'assistant' then
    -- Streamed messages were rendered from stream_events and this complete
    -- copy is reconciliation only. Synthetic API-error messages (rate
    -- limit, auth, billing, max output tokens) never stream: this is their
    -- only appearance, tagged with `error`.
    if msg.error ~= nil then
      self:_handle_assistant_error(msg)
    end
  elseif t == 'user' then
    background_changed = self:_handle_user(msg)
  elseif t == 'result' then
    self:_handle_result(msg)
  elseif t == 'control_request' then
    self:_handle_control_request(msg)
  elseif t == 'control_response' then
    self:_handle_control_response(msg)
  elseif t == 'control_cancel_request' then
    self:_handle_control_cancel(msg)
  elseif t == 'tool_progress' then
    self:_handle_tool_progress(msg)
  elseif t == 'tool_use_summary' then
    -- Could surface as a status line; skip for now.
  elseif t == 'command_lifecycle' then
    -- Prompt UUIDs trigger queue lifecycle acknowledgements; no UI action needed.
  elseif t == 'rate_limit' or t == 'rate_limit_event' then
    self:_handle_rate_limit(msg)
  elseif t == 'api_retry' then
    self.output:render_notice('API retry')
  elseif t == 'hook_started' then
    self:_handle_hook(msg, 'started')
  elseif t == 'hook_progress' then
    -- Usually noisy; skip. Could plumb through if needed.
  elseif t == 'hook_response' then
    self:_handle_hook(msg, 'response')
  elseif t == 'task_notification' then
    -- Current CLIs send this as system/task_notification (handled in
    -- _handle_system); keep the top-level form for older emitters.
    background_changed = self:_handle_task_notification(msg)
  end

  -- Approvals of classifier denials wait for the turn to end.
  if before_turn_active and not self.session.turn_active and self.instance
      and self.instance.queued_prompts then
    local inst = self.instance
    vim.schedule(function() require('cc')._flush_queued_prompts(inst) end)
  end

  -- Refresh statusline on events that change visible state.
  if t == 'system' or t == 'result' or t == 'control_response'
      or t == 'control_cancel_request'
      or background_changed or before_turn_active ~= self.session.turn_active then
    refresh_statusline(self)
  end
end

function Router:_handle_hook(msg, phase)
  local hook_name = msg.hook_event_name or msg.hook or 'hook'
  local elapsed = msg.elapsed_time_seconds
  self.output:render_hook(hook_name, phase, elapsed)
end

function Router:_handle_system(msg)
  local sub = msg.subtype
  if sub == 'init' then
    self.session:on_init(msg)
    if msg.session_id and self.on_session_id then
      self.on_session_id(msg.session_id)
    end
    if self.instance then
      require('cc')._flush_pending_rename(self.instance)
    end
  elseif sub == 'bridge_state' then
    self.session.remote_control_state = msg.state
    self.session.remote_control_detail = msg.detail
    self.remote_control_failure = nil
    if msg.state == 'failed' or msg.state == 'policy_disabled' then
      -- Terminal: the transport gave up (auth, superseded worker, version)
      -- or the org policy refused the bridge. `reconnecting` is the only
      -- state the CLI recovers from on its own; these need a new enable.
      local detail = msg.detail or 'bridge failed'
      self.remote_control_failure = detail
      local text = string.format(Config.options.remote_control.failed_format, detail)
      self.output:render_notice(text)
      vim.notify('cc.nvim: ' .. text, vim.log.levels.WARN)
    end
  elseif sub == 'compact_boundary' then
    self.output:render_notice('Context Compacted')
  elseif sub == 'status' then
    if msg.status == 'compacting' then
      self.output:render_notice('Compacting context...')
    end
    -- The CLI emits a system/status message with `permissionMode` set
    -- whenever the live mode changes (Shift+Tab, /plan, ExitPlanMode dialog,
    -- our set_permission_mode control_request, etc.). Mirror it onto the
    -- session so the statusline refreshes to the new mode.
    if msg.permissionMode and self.session then
      self.session.permission_mode = msg.permissionMode
    end
  elseif sub == 'permission_denied' then
    self:_handle_permission_denied(msg)
  elseif sub == 'peer_message_hold' then
    self:_handle_peer_message_hold(msg)
  elseif sub == 'task_notification' then
    self:_handle_task_notification(msg)
  elseif sub == 'task_started' or sub == 'task_progress' or sub == 'task_updated'
      or sub == 'background_tasks_changed' then
    -- Subagent lifecycle. The nested Activity section is driven by the
    -- parent_tool_use_id-tagged messages instead, which carry the actual
    -- tool calls; these summaries add nothing the user can't already see.
  end
end

--- Render a message emitted from inside a subagent (parent_tool_use_id set)
--- under the parent Agent tool block. Subagent assistant messages arrive as
--- completed blocks (one per message), never as stream_event deltas.
---@param parent_id string
---@param msg table
function Router:_handle_subagent_message(parent_id, msg)
  local t = msg.type
  if t == 'assistant' or t == 'user' then
    local message = msg.message
    local content = message and message.content
    if type(content) ~= 'table' then return end
    for _, block in ipairs(content) do
      if type(block) == 'table' then
        if t == 'assistant' and block.type == 'tool_use' then
          self.output:subagent_tool_use(parent_id, block)
        elseif t == 'assistant' and block.type == 'text' then
          self.output:subagent_text(parent_id, block.text)
        elseif t == 'assistant' and block.type == 'thinking' then
          self.output:subagent_thinking(parent_id, block.thinking)
        elseif t == 'user' and block.type == 'tool_result' then
          self.output:subagent_tool_result(parent_id, block.tool_use_id, block.content, block.is_error)
        end
        -- user text blocks echo the subagent prompt, already shown as the
        -- parent tool's input.
      end
    end
  elseif t == 'tool_progress' then
    if msg.tool_use_id and msg.elapsed_time_seconds then
      self.output:update_tool_elapsed(msg.tool_use_id, msg.elapsed_time_seconds)
    end
  end
end

function Router:_handle_stream_event(msg)
  local event = msg.event
  if not event then return end
  local et = event.type
  if et == 'message_start' then
    -- A new turn proves the interrupted turn had no trailing result.
    self.interrupted_result_pending = false
    self.session:begin_message(event.message)
    self.output:begin_assistant_turn()
  elseif et == 'content_block_start' then
    local idx = event.index or 0
    local block = event.content_block or {}
    self.session:begin_block(idx, block)
    if block.type == 'tool_use' and block.id then
      self.session:begin_tool_call(block.id, block.name)
    end
    self.output:on_content_block_start(block)
    if block.type == 'tool_use' and block.id then
      self.output:start_tool_timer(block.id)
    end
  elseif et == 'content_block_delta' then
    local idx = event.index or 0
    local kind, chunk = self.session:apply_delta(idx, event.delta or {})
    if kind and chunk then
      self.output:on_delta(kind, chunk)
    end
  elseif et == 'content_block_stop' then
    local idx = event.index or 0
    local block = self.session.current_blocks[idx]
    self.session:end_block(idx)
    if block and block.type == 'tool_use' and block.id then
      self.session:finalize_tool_call(block.id, block.input)
    end
    self.output:on_content_block_stop(block)
  elseif et == 'message_stop' then
    self.session:end_message()
    self.output:end_assistant_turn()
  end
end

--- Handle prompt replays and tool_result blocks produced by Claude Code.
---@param msg table
---@return boolean changed
function Router:_handle_user(msg)
  local message = msg.message
  if not message or message.role ~= 'user' then return false end
  local content = message.content
  if msg.isReplay == true and (msg.parent_tool_use_id == nil or msg.parent_tool_use_id == vim.NIL) then
    if msg.isSynthetic == true or msg.isMeta == true then return false end
    if type(msg.uuid) == 'string' and self.session:consume_sent_prompt(msg.uuid) then
      return false
    end
    local text = ''
    if type(content) == 'string' then
      text = content
    elseif type(content) == 'table' then
      local parts = {}
      for _, block in ipairs(content) do
        if type(block) == 'table' then
          if block.type == 'text' then
            if type(block.text) == 'string' then table.insert(parts, block.text) end
          elseif type(block.type) == 'string' then
            table.insert(parts, string.format(Config.options.remote_control.content_block_format, block.type))
          end
        end
      end
      text = table.concat(parts, '\n')
    end
    if text == '' then return false end
    require('cc.splash').clear(self.output.bufnr)
    self.output:follow_tail()
    self.session:add_user_turn(text)
    if self.instance then self.instance.blocked = nil end
    self.output:render_user_turn(text)
    return false
  end
  if type(content) == 'string' then
    if content:match('^%s*<task%-notification>') then
      return self.session:finish_background_task(
        content:match('<tool%-use%-id>(.-)</tool%-use%-id>'),
        content:match('<task%-id>(.-)</task%-id>'))
    end
    return false
  end
  if type(content) ~= 'table' then return false end
  if is_interrupt_marker(content) then
    self:_on_interrupt_marker()
    return false
  end
  local changed = false
  for _, block in ipairs(content) do
    if type(block) == 'table' and block.type == 'tool_result' then
      local tool_use_id = block.tool_use_id
      self.session:record_tool_result(tool_use_id, block.content, block.is_error)
      self.output:render_tool_result(tool_use_id, block.content, block.is_error)
      pcall(function() require('cc.peek').notify_tool_result(tool_use_id, block.is_error) end)
      local call = self.session.tool_calls[tool_use_id]
      local input = call and call.input
      if not block.is_error and call
          and ((type(input) == 'table' and input.run_in_background == true)
            or call.name == 'Monitor') then
        self.session:begin_background_task(tool_use_id, launched_task_id(msg, block))
        changed = true
      end
    end
  end
  return changed
end

--- Stamp the live turn as interrupted, once, whichever signal lands first:
--- the control_response to our own interrupt or the CLI's interrupt marker.
---@param text string? notice text; nil renders the default 'Interrupted'
function Router:_finish_interrupted_turn(text)
  if self.interrupted_result_pending then return end
  self.output:stop_all_tool_timers()
  -- Claude versions differ on whether they emit a trailing `result` (2.1.x
  -- sends `error_during_execution`). Absorb it as state-only so neither an
  -- error notice nor cumulative cost/usage is shown for this turn.
  self.interrupted_result_pending = true
  local timing = self.session:finish_turn()
  require('cc.seen').on_turn_finished(self.instance)
  self.output:render_interrupted(timing, text)
  self.output:on_turn_finished(self.instance)
end

--- A turn we did not ask to stop was aborted from claude.ai. When we did ask
--- (interrupt_pending), the marker merely confirms it, possibly ahead of the
--- control_response, and renders the plain notice.
function Router:_on_interrupt_marker()
  if not self.session.turn_active then return end
  local text = nil
  if not self.session.interrupt_pending then
    text = Config.options.remote_control.interrupted_notice
  end
  self:_finish_interrupted_turn(text)
end

function Router:_handle_result(msg)
  local interrupted = self.interrupted_result_pending
  self.interrupted_result_pending = false
  self.session:on_result(msg, interrupted)
  if not interrupted then require('cc.seen').on_turn_finished(self.instance) end
  -- A `result` is the terminal message of a turn; every tool should have
  -- completed by now. Any timer still running is orphaned (its tool_result
  -- never arrived), so stop it before the cost line lands.
  self.output:stop_all_tool_timers()
  if not interrupted then
    -- An error result usually echoes the assistant error already shown
    -- (rate limit, auth failure); only render text we have not rendered.
    local err = ErrorNotice.format_result_error(msg)
    if err and err ~= self.last_error_text then
      self.output:render_notice(err)
      vim.notify('cc.nvim: ' .. err, vim.log.levels.WARN)
    end
    self.output:render_result(msg)
    self.output:on_turn_finished(self.instance)
  end
  self.last_error_text = nil
  if self.instance then
    require('cc')._flush_pending_rename(self.instance)
  end
end

--- Surface claude.ai usage-limit changes. The CLI emits one event per
--- status change, including the return to `allowed`; we render warnings,
--- rejections, and the lift after either, and drop the rest.
---@param msg table SDKRateLimitEvent
function Router:_handle_rate_limit(msg)
  local info = msg.rate_limit_info
  if type(info) ~= 'table' then return end
  require('cc.limits_log').record_claude(info)
  local key = table.concat({
    tostring(info.status), tostring(info.rateLimitType), tostring(info.resetsAt),
    tostring(info.isUsingOverage),
  }, '|')
  if key == self.rate_limit_key then return end
  local text = ErrorNotice.format_rate_limit(info, self.rate_limit_status)
  self.rate_limit_key = key
  self.rate_limit_status = info.status
  if not text then return end
  self.output:render_notice(text)
  if info.status == 'rejected' then
    vim.notify('cc.nvim: ' .. text, vim.log.levels.WARN)
  end
end

--- Render a synthetic API-error assistant message as an error notice.
---@param msg table SDKAssistantMessage with `error` set
function Router:_handle_assistant_error(msg)
  local text = ErrorNotice.format_assistant_error(msg)
  if not text then return end
  self.last_error_text = text
  self.output:render_notice(text)
  vim.notify('cc.nvim: ' .. text, vim.log.levels.WARN)
end

function Router:_handle_tool_progress(msg)
  local tool_use_id = msg.tool_use_id
  local elapsed = msg.elapsed_time_seconds
  if tool_use_id and elapsed then
    self.output:update_tool_elapsed(tool_use_id, elapsed)
  end
end

---@param msg table
function Router:_handle_control_cancel(msg)
  local entry = self.open_prompts[msg.request_id]
  if not entry then return end
  if entry.finish then
    entry.finish(nil, 'remote')
    return
  end
  self.open_prompts[msg.request_id] = nil
  pcall(entry.dismiss)
  self.output:render_permission_outcome('remote', entry.tool_name)
  if self.instance then
    local waiting = next(self.open_prompts) ~= nil
    self.instance.awaiting_permission = waiting
    self.instance.awaiting_input = waiting
    require('cc.statusline').refresh(self.instance)
  end
end

function Router:_handle_control_response(msg)
  local resp = msg.response
  if not resp or not resp.request_id then return end
  local pending
  if self.process and self.process.consume_pending_control_entry then
    pending = self.process:consume_pending_control_entry(resp.request_id)
  elseif self.process then
    local subtype = self.process:consume_pending_control(resp.request_id)
    if subtype then pending = { subtype = subtype } end
  end
  if not pending then
    local entry = self.open_prompts[resp.request_id]
    if entry and entry.finish then
      local behavior = type(resp.response) == 'table' and resp.response.behavior
      if behavior ~= 'allow' and behavior ~= 'deny' then behavior = nil end
      entry.finish(behavior, 'remote')
    elseif entry then
      self.open_prompts[resp.request_id] = nil
      pcall(entry.dismiss)
      local behavior = type(resp.response) == 'table' and resp.response.behavior
      if behavior ~= 'allow' and behavior ~= 'deny' then behavior = 'remote' end
      self.output:render_permission_outcome(behavior, entry.tool_name)
      if self.instance then
        local waiting = next(self.open_prompts) ~= nil
        self.instance.awaiting_permission = waiting
        self.instance.awaiting_input = waiting
        require('cc.statusline').refresh(self.instance)
      end
    end
  end
  local subtype = pending and pending.subtype
  if subtype == 'interrupt' then
    if self.session then
      self.session.interrupt_pending = false
      self.session.is_streaming = false
      self.session.turn_active = false
    end
    if resp.subtype == 'success' then
      self:_finish_interrupted_turn()
    else
      local err = resp.error or 'control_response error'
      self.output:render_notice('Interrupt failed: ' .. tostring(err))
    end
  elseif subtype == 'set_permission_mode' then
    -- The CLI refuses some switches (bypassPermissions when the session
    -- was not launched with --dangerously-skip-permissions or bypass is
    -- disabled by settings; auto when unavailable). Nothing else reports
    -- it, so surface the CLI's reason in the transcript and as a warning.
    if resp.subtype ~= 'success' then
      local err = resp.error or 'control_response error'
      local text = 'Permission mode change failed: ' .. tostring(err)
      self.output:render_notice(text)
      vim.notify('cc.nvim: ' .. text, vim.log.levels.WARN)
      if self.instance then
        require('cc.statusline').refresh(self.instance)
      end
    end
  elseif subtype == 'remote_control' then
    local cfg = Config.options.remote_control
    if resp.subtype == 'success' then
      local inner = resp.response or {}
      if inner.session_url then
        self.remote_control_failure = nil
        self.session.remote_control_url = inner.session_url
        self.session.remote_control_bridge_id = inner.bridge_session_id
        if not pending.silent then
          self.output:render_notice(string.format(cfg.notice_format, inner.session_url))
        end
      else
        self.session.remote_control_state = nil
        self.session.remote_control_detail = nil
        self.session.remote_control_url = nil
        self.session.remote_control_bridge_id = nil
        if not pending.silent then self.output:render_notice(cfg.disabled_notice) end
      end
    elseif not pending.silent then
      local err = resp.error or 'control_response error'
      -- An enable that died inside the bridge init already reported itself
      -- through bridge_state failed/policy_disabled with this same text.
      if err ~= self.remote_control_failure then
        local text = string.format(cfg.error_format, err)
        self.output:render_notice(text)
        vim.notify('cc.nvim: ' .. text, vim.log.levels.WARN)
      end
    end
  elseif subtype == 'rename_session' then
    -- The CLI persists the title and pushes it to the bridge itself; only
    -- failures need surfacing (empty title, session_id mismatch).
    if resp.subtype ~= 'success' then
      local text = string.format(Config.options.remote_control.rename_error_format,
        resp.error or 'control_response error')
      self.output:render_notice(text)
      vim.notify('cc.nvim: ' .. text, vim.log.levels.WARN)
    end
  elseif subtype == 'get_settings' then
    if resp.subtype ~= 'success' then return end
    if not self.session then return end
    local inner = resp.response or {}
    -- Capture the CLI's resolved effort level (the `applied` section reports
    -- the fully-resolved value, including the model default when no env/setting
    -- pins it — e.g. 'auto' resolving to 'high' on Opus). The statusline uses
    -- this to show what 'auto' resolves to. Captured independently of the
    -- permission_mode seeding below, which may bail early on an init race.
    local applied = inner.applied or {}
    if type(applied.model) == 'string' and applied.model ~= '' then
      if self.session.model and self.session.model ~= applied.model then
        self.session.context_window = nil
      end
      self.session.model = applied.model
    end
    if type(applied.effort) == 'string' and applied.effort ~= '' then
      self.session.resolved_effort = applied.effort
    end
    -- Seed session.permission_mode from the CLI's effective settings so the
    -- statusline shows the right mode before the user's first prompt
    -- triggers an init message. Only fill in if nothing has set it yet —
    -- if init or a set_permission_mode raced us, defer to that authoritative
    -- value. permissions.defaultMode is optional; fall back to 'default'
    -- (the CLI's own ultimate fallback when no settings layer specifies one).
    if not self.session.permission_mode then
      local effective = inner.effective or {}
      local permissions = effective.permissions or {}
      self.session.permission_mode = permissions.defaultMode or 'default'
    end
    if self.instance then
      require('cc.statusline').refresh(self.instance)
    end
  end
  if pending and pending.callback then
    local ok = resp.subtype == 'success'
    local called, err = pcall(pending.callback, ok, resp)
    if not called then
      vim.notify('cc.nvim: control response callback failed: ' .. tostring(err),
        vim.log.levels.ERROR)
    end
  end
end

function Router:_handle_control_request(msg)
  local req = msg.request
  if not req then return end
  if self.instance then
    self.instance.awaiting_permission = true
    self.instance.awaiting_input = true
    require('cc.statusline').refresh(self.instance)
  end
  if req.subtype == 'can_use_tool' then
    self:_handle_permission_request(msg.request_id, req)
  elseif req.subtype == 'elicitation' then
    self:_handle_interactive_request(msg.request_id, req, 'elicitation', 'handle_elicitation')
  end
end

---@param request_id string
---@param req table
---@param tool_name string
---@param handler string
function Router:_handle_interactive_request(request_id, req, tool_name, handler)
  local answered = false
  local handle = require('cc.interactive')[handler](
    self.process, self.output, request_id, req, self.instance, function()
      self.open_prompts[request_id] = nil
      answered = true
    end)
  if not answered then
    self.open_prompts[request_id] = { tool_name = tool_name, dismiss = handle.dismiss }
  end
end

function Router:_handle_permission_request(request_id, req)
  local tool_name = req.tool_name or 'unknown'
  local input = req.input
  local tool_use_id = req.tool_use_id
  local suggestions = req.permission_suggestions

  -- Specialized handlers for interactive CC features.
  if tool_name == 'EnterPlanMode' then
    self:_handle_interactive_request(request_id, req, tool_name, 'handle_enter_plan_mode')
    return
  elseif tool_name == 'ExitPlanMode' then
    self:_handle_interactive_request(request_id, req, tool_name, 'handle_exit_plan_mode')
    return
  elseif tool_name == 'AskUserQuestion' then
    self:_handle_interactive_request(request_id, req, tool_name, 'handle_ask_user_question')
    return
  end

  self:_supersede_denials(tool_name, input)
  self.output:render_permission_request(tool_name, input)

  require('cc.permission_prompt').request(tool_name, input, function(behavior, variant, message, source)
    self.output:render_permission_outcome(behavior or 'remote', tool_name)
    if source == 'remote' or source == 'closed' then return end
    local response_body = self:_build_permission_response(
      behavior, variant, tool_name, input, tool_use_id, suggestions)
    if behavior == 'deny' and message ~= nil then response_body.message = message end
    if self.process then
      self.process:write({
        type = 'control_response',
        response = {
          request_id = request_id,
          subtype = 'success',
          response = response_body,
        },
      })
    end
  end, { provider = 'claude', instance = self.instance,
    request_id = request_id, pending = self.open_prompts })
end

--- Substitute ${name} placeholders; gsub's replacement is a function so `%`
--- in values stays literal.
---@param template string
---@param values table<string, string>
---@return string
local function fill(template, values)
  return (template:gsub('%${([%w_]+)}', function(key) return values[key] end))
end

---@param input table?
---@return string
local function input_json(input)
  if type(input) ~= 'table' then return '{}' end
  local ok, json = pcall(vim.json.encode, input)
  if not ok then return '{}' end
  -- cjson escapes '/' as '\/'; commands and paths read better without it.
  return (json:gsub('\\/', '/'))
end

--- An auto-mode classifier block (system/permission_denied). The CLI has
--- already denied the call and asks nothing, so this opens the permission
--- prompt flow (float, hooks, timeout stages) for a request that exists only
--- here. Approve submits a user message authorizing the exact call; Dismiss,
--- timeouts, and teardown send nothing. Subagent blocks (agent_id) arrive on
--- the parent stream and surface the same way.
---@param msg table
function Router:_handle_permission_denied(msg)
  self:_emit_permission_denied(msg)
  local opts = Config.options.permission_denials or {}
  if opts.enabled == false or msg.decision_reason_type ~= 'classifier' then return end
  local tool_use_id = msg.tool_use_id
  local request_id = 'denial:' .. tostring(tool_use_id or msg.uuid or '')
  if self.open_prompts[request_id] then return end
  local tool_name = msg.tool_name or 'unknown'
  local input = self.output:tool_input(tool_use_id)
  local reason = msg.decision_reason
  if type(reason) ~= 'string' or reason == '' then reason = msg.message end
  local agent_id = type(msg.agent_id) == 'string' and msg.agent_id ~= '' and msg.agent_id or nil
  local inst = self.instance

  self.output:render_permission_denial(tool_name, input, reason)
  require('cc.permission_prompt').request(tool_name, input, function(behavior, _, _, source)
    if source == 'superseded' then return end
    self.output:render_permission_outcome(behavior or 'deny', tool_name, 'denial')
    if behavior ~= 'allow' or source == 'closed' or not inst then return end
    local text = fill(opts.approve_prompt or '', {
      tool_name = tool_name,
      input = input_json(input or self.output:tool_input(tool_use_id)),
      reason = reason or '',
      where = agent_id and (' inside subagent ' .. agent_id) or '',
    })
    local ok, err = require('cc')._submit_when_idle(inst, text)
    if not ok then
      vim.notify('cc.nvim: approval not sent: ' .. tostring(err), vim.log.levels.WARN)
    end
  end, { provider = 'claude', instance = inst, request_id = request_id,
    pending = self.open_prompts, kind = 'denial', reason = reason,
    tool_use_id = tool_use_id, agent_id = agent_id })
end

--- Fire `User CcPermissionDenied` for every system/permission_denied, of any
--- decision type (classifier, rule, subcommandResults, ...), so a config can
--- log or escalate blocks that never open a prompt. PreToolUse hook denials
--- never reach the stream; the hook has to report those itself.
---@param msg table
function Router:_emit_permission_denied(msg)
  local inst = self.instance
  local input = self.output:tool_input(msg.tool_use_id)
  local reason = msg.decision_reason
  if type(reason) ~= 'string' or reason == '' then reason = nil end
  local ok, err = pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = 'CcPermissionDenied',
    modeline = false,
    data = {
      bufnr = self.output.bufnr,
      prompt_bufnr = inst and inst.prompt and inst.prompt.bufnr or nil,
      session_id = (inst and inst.last_session_id) or (self.session and self.session.id) or nil,
      session_name = inst and (inst.session_name or inst.pending_session_name) or nil,
      cwd = inst and inst.cwd or nil,
      tool_name = msg.tool_name,
      tool_use_id = msg.tool_use_id,
      input = input,
      decision_reason_type = msg.decision_reason_type,
      reason = reason,
      message = msg.message,
      agent_id = type(msg.agent_id) == 'string' and msg.agent_id or nil,
    },
  })
  if not ok then
    self.output:render_notice('CcPermissionDenied handler failed: ' .. tostring(err))
  end
end

---@param a table?
---@param b table?
---@return boolean true when two tool inputs name the same call (Bash by command)
local function same_call(tool_name, a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  if tool_name == 'Bash' then return a.command ~= nil and a.command == b.command end
  local function strip(t)
    local copy = vim.deepcopy(t)
    copy.description = nil
    return copy
  end
  return vim.deep_equal(strip(a), strip(b))
end

--- A real prompt for a call the classifier blocked earlier (a PermissionDenied
--- hook asked the model to retry, a PreToolUse hook turned the retry into a
--- prompt) replaces that block's Approve/Dismiss float: one prompt, one push.
---@param tool_name string
---@param input table?
function Router:_supersede_denials(tool_name, input)
  for _, entry in pairs(vim.tbl_values(self.open_prompts)) do
    if entry.kind == 'denial' and entry.finish and entry.tool_name == tool_name
        and same_call(tool_name, entry.input, input) then
      entry.finish(nil, 'superseded')
      self.output:render_notice(string.format(
        Config.options.permission_denials.superseded_notice or '', tool_name))
    end
  end
end

--- A cross-session message the CLI parked (system/peer_message_hold). The
--- CLI's approval dialog is TUI-only, so a hold here can only end in expiry
--- unless the modes come to match; say so where the user is looking.
--- `released` means it entered the queue and needs no notice.
---@param msg table
function Router:_handle_peer_message_hold(msg)
  local key = msg.message_uuid or msg.uuid
  if type(key) ~= 'string' then return end
  local holds = self.session.peer_holds
  if msg.state == 'released' then
    holds[key] = nil
    return
  end
  if msg.state ~= 'held' and msg.state ~= 'dropped' then return end
  local from = msg.from_name or msg.from or 'another session'
  local uv = vim.uv or vim.loop
  local seconds, microseconds = uv.gettimeofday()
  holds[key] = {
    from = msg.from or '',
    from_name = msg.from_name,
    state = msg.state,
    cause = msg.cause or (holds[key] and holds[key].cause),
    outcome = msg.outcome,
    at = seconds * 1000 + math.floor(microseconds / 1000),
  }
  local opts = Config.options.peer_message_hold or {}
  if opts.enabled == false then return end
  local template = msg.state == 'held' and opts.held_format or opts.dropped_format
  if type(template) ~= 'string' or template == '' then return end
  local text = fill(template, {
    from = from, cause = msg.cause or 'unknown', outcome = msg.outcome or 'unknown',
  })
  self.output:render_notice(text)
  vim.notify('cc.nvim: ' .. text, vim.log.levels.WARN)
end

--- Build the `response` body for a can_use_tool control_response.
---
--- For `allow_always`, the CLI's `permission_suggestions` (if it sent any)
--- are echoed back as `updatedPermissions` so the rule lands at whatever
--- destination the CLI computed (typically `localSettings`, persisting to
--- `.claude/settings.local.json`). When the CLI sent no suggestions we
--- synthesize a coarse fallback that allows the whole tool, project-scoped.
--- See coreSchemas.ts:PermissionResultSchema for the response shape.
---@param behavior 'allow'|'deny'
---@param variant 'allow_once'|'allow_always'|'deny'|'cancel'
---@param tool_name string
---@param input table?
---@param tool_use_id string?
---@param suggestions table[]? PermissionUpdate[] from req.permission_suggestions
---@return table
function Router:_build_permission_response(
    behavior, variant, tool_name, input, tool_use_id, suggestions)
  if behavior == 'allow' then
    local body = {
      behavior = 'allow',
      updatedInput = input,
      toolUseID = tool_use_id,
    }
    if variant == 'allow_always' then
      if suggestions and #suggestions > 0 then
        body.updatedPermissions = suggestions
      else
        body.updatedPermissions = {
          {
            type = 'addRules',
            rules = { { toolName = tool_name } },
            behavior = 'allow',
            destination = 'localSettings',
          },
        }
      end
      body.decisionClassification = 'user_permanent'
    else
      body.decisionClassification = 'user_temporary'
    end
    return body
  end
  return {
    behavior = 'deny',
    message = 'User denied via cc.nvim',
    toolUseID = tool_use_id,
    decisionClassification = 'user_reject',
  }
end

M.Router = Router
return M
