-- Dispatches SDK NDJSON messages to session (state) and output (render).

local M = {}

---@class cc.Router
---@field session cc.Session
---@field output cc.Output
---@field process cc.Process?
---@field instance cc.Instance?
---@field on_session_id fun(session_id: string)?
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
  }, Router)
end

local function refresh_statusline(self)
  if self.instance then
    require('cc.statusline_spinner').sync(self.instance)
    require('cc.statusline').refresh(self.instance)
  end
end

function Router:set_process(process)
  self.process = process
end

---@param msg table SDK NDJSON message
function Router:dispatch(msg)
  local t = msg.type
  local before_turn_active = self.session.turn_active
  if t == 'system' then
    self:_handle_system(msg)
  elseif t == 'stream_event' then
    self:_handle_stream_event(msg)
  elseif t == 'assistant' then
    -- Post-streaming reconciliation; UI already current.
  elseif t == 'user' then
    self:_handle_user(msg)
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
    self.output:render_task('done', msg.summary or msg.description or '')
  end

  -- Refresh statusline on events that change visible state.
  if t == 'system' or t == 'result' or t == 'control_response'
      or before_turn_active ~= self.session.turn_active then
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
  end
end

function Router:_handle_stream_event(msg)
  local event = msg.event
  if not event then return end
  local et = event.type
  if et == 'message_start' then
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
  if not message or message.role ~= 'user' then return end
  local content = message.content
  if type(content) ~= 'table' then return end
  for _, block in ipairs(content) do
    if type(block) == 'table' and block.type == 'tool_result' then
      local tool_use_id = block.tool_use_id
      self.session:record_tool_result(tool_use_id, block.content, block.is_error)
      self.output:render_tool_result(tool_use_id, block.content, block.is_error)
      pcall(function() require('cc.peek').notify_tool_result(tool_use_id, block.is_error) end)
    end
  end
end

function Router:_handle_result(msg)
  self.session:on_result(msg)
  -- A `result` is the terminal message of a turn; every tool should have
  -- completed by now. Any timer still running is orphaned (its tool_result
  -- never arrived), so stop it before the cost line lands.
  self.output:stop_all_tool_timers()
  self.output:render_result(msg)
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
  local subtype = self.process and self.process:consume_pending_control(resp.request_id)
  if subtype == 'interrupt' then
    if self.session then
      self.session.interrupt_pending = false
      self.session.is_streaming = false
      self.session.turn_active = false
    end
    if resp.subtype == 'success' then
      -- A successful interrupt aborts the turn without a `result` message, so
      -- any in-flight tool's timer would otherwise tick forever — stop them.
      self.output:stop_all_tool_timers()
      self.output:render_notice('Interrupted')
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
end

function Router:_handle_control_request(msg)
  local req = msg.request
  if not req then return end
  if self.instance then
    self.instance.remote_control_active = true
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
      require('cc.statusline').refresh(self.instance)
    end
  end)
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
