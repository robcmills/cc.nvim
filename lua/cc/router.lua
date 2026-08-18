-- Dispatches SDK NDJSON messages to session (state) and output (render).

local M = {}

---@class cc.Router
---@field session cc.Session
---@field output cc.Output
---@field process cc.Process?
---@field instance cc.Instance?
---@field on_session_id fun(session_id: string)?
---@field interrupted_result_pending boolean true after an acknowledged interrupt until Claude's optional trailing result
local Router = {}
Router.__index = Router

---@param opts { session: cc.Session, output: cc.Output, process: cc.Process?, instance: cc.Instance?, on_session_id: fun(session_id: string)? }
function M.new(opts)
  return setmetatable({
    session = opts.session,
    output = opts.output,
    process = opts.process,
    instance = opts.instance,
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
  local before_turn_active = self.session.turn_active
  local background_changed = false
  if t == 'system' then
    self:_handle_system(msg)
  elseif t == 'stream_event' then
    self:_handle_stream_event(msg)
  elseif t == 'assistant' then
    -- Post-streaming reconciliation; UI already current.
  elseif t == 'user' then
    background_changed = self:_handle_user(msg)
  elseif t == 'result' then
    self:_handle_result(msg)
  elseif t == 'control_request' then
    self:_handle_control_request(msg)
  elseif t == 'control_response' then
    self:_handle_control_response(msg)
  elseif t == 'tool_progress' then
    self:_handle_tool_progress(msg)
  elseif t == 'tool_use_summary' then
    -- Could surface as a status line; skip for now.
  elseif t == 'rate_limit' or t == 'rate_limit_event' then
    -- No-op for MVP.
  elseif t == 'api_retry' then
    self.output:render_notice('API retry')
  elseif t == 'hook_started' then
    self:_handle_hook(msg, 'started')
  elseif t == 'hook_progress' then
    -- Usually noisy; skip. Could plumb through if needed.
  elseif t == 'hook_response' then
    self:_handle_hook(msg, 'response')
  elseif t == 'task_started' then
    self.output:render_task('started', msg.description or msg.agent_name or '')
  elseif t == 'task_progress' then
    -- Skip; tool_progress inside the subagent handles fine-grained updates.
  elseif t == 'task_notification' then
    background_changed = self:_handle_task_notification(msg)
    self.output:render_task('done', msg.summary or msg.description or '')
  end

  -- Refresh statusline on events that change visible state.
  if t == 'system' or t == 'result' or t == 'control_response'
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
  elseif sub == 'task_notification' then
    self:_handle_task_notification(msg)
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

--- Handle user-type NDJSON messages. These carry tool_result blocks that
--- Claude Code produces after executing tools.
function Router:_handle_user(msg)
  local message = msg.message
  if not message or message.role ~= 'user' then return false end
  local content = message.content
  if type(content) == 'string' then
    if content:match('^%s*<task%-notification>') then
      return self.session:finish_background_task(
        content:match('<tool%-use%-id>(.-)</tool%-use%-id>'),
        content:match('<task%-id>(.-)</task%-id>'))
    end
    return false
  end
  if type(content) ~= 'table' then return false end
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

function Router:_handle_result(msg)
  local interrupted = self.interrupted_result_pending
  self.interrupted_result_pending = false
  self.session:on_result(msg, interrupted)
  -- A `result` is the terminal message of a turn; every tool should have
  -- completed by now. Any timer still running is orphaned (its tool_result
  -- never arrived), so stop it before the cost line lands.
  self.output:stop_all_tool_timers()
  if not interrupted then
    self.output:render_result(msg)
  end
  if self.instance then
    require('cc')._flush_pending_rename(self.instance)
  end
end

function Router:_handle_tool_progress(msg)
  local tool_use_id = msg.tool_use_id
  local elapsed = msg.elapsed_time_seconds
  if tool_use_id and elapsed then
    self.output:update_tool_elapsed(tool_use_id, elapsed)
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
  local subtype = pending and pending.subtype
  if subtype == 'interrupt' then
    if self.session then
      self.session.interrupt_pending = false
      self.session.is_streaming = false
      self.session.turn_active = false
    end
    if resp.subtype == 'success' then
      -- Claude versions differ on whether they emit a trailing `result`.
      -- Stamp the acknowledged interrupt now, then absorb any such result as
      -- state-only so cumulative cost/usage is never shown for this turn.
      self.output:stop_all_tool_timers()
      self.interrupted_result_pending = true
      self.output:render_interrupted(self.session:finish_turn())
    else
      local err = resp.error or 'control_response error'
      self.output:render_notice('Interrupt failed: ' .. tostring(err))
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
    self.instance.remote_control_active = true
    self.instance.awaiting_input = true
    require('cc.statusline').refresh(self.instance)
  end
  if req.subtype == 'can_use_tool' then
    self:_handle_permission_request(msg.request_id, req)
  elseif req.subtype == 'elicitation' then
    require('cc.interactive').handle_elicitation(
      self.process, self.output, msg.request_id, req, self.instance)
  end
end

function Router:_handle_permission_request(request_id, req)
  local tool_name = req.tool_name or 'unknown'
  local input = req.input
  local tool_use_id = req.tool_use_id
  local suggestions = req.permission_suggestions

  -- Specialized handlers for interactive CC features.
  if tool_name == 'EnterPlanMode' then
    require('cc.interactive').handle_enter_plan_mode(
      self.process, self.output, request_id, req, self.instance)
    return
  elseif tool_name == 'ExitPlanMode' then
    require('cc.interactive').handle_exit_plan_mode(
      self.process, self.output, request_id, req, self.instance)
    return
  elseif tool_name == 'AskUserQuestion' then
    require('cc.interactive').handle_ask_user_question(
      self.process, self.output, request_id, req, self.instance)
    return
  end

  self.output:render_permission_request(tool_name, input)

  require('cc.permission_prompt').ask(tool_name, input, function(behavior, variant)
    local response_body = self:_build_permission_response(
      behavior, variant, tool_name, input, tool_use_id, suggestions)
    self.output:render_permission_outcome(behavior, tool_name)
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
    if self.instance then
      self.instance.remote_control_active = false
      self.instance.awaiting_input = false
      require('cc.statusline').refresh(self.instance)
    end
  end, { provider = 'claude', instance = self.instance })
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
