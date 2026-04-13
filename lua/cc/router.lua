-- Dispatches SDK NDJSON messages to session (state) and output (render).

local M = {}

---@class cc.Router
---@field session cc.Session
---@field output cc.Output
---@field process cc.Process?
---@field on_session_id fun(session_id: string)?
local Router = {}
Router.__index = Router

---@param opts { session: cc.Session, output: cc.Output, process: cc.Process?, on_session_id: fun(session_id: string)? }
function M.new(opts)
  return setmetatable({
    session = opts.session,
    output = opts.output,
    process = opts.process,
    on_session_id = opts.on_session_id,
  }, Router)
end

function Router:set_process(process)
  self.process = process
end

---@param msg table SDK NDJSON message
function Router:dispatch(msg)
  local t = msg.type
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
  elseif sub == 'compact_boundary' then
    self.output:render_notice('Context Compacted')
  elseif sub == 'status' then
    if msg.status == 'compacting' then
      self.output:render_notice('Compacting context...')
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
    end
  end
end

function Router:_handle_result(msg)
  self.session:on_result(msg)
  self.output:render_result(msg)
end

function Router:_handle_tool_progress(msg)
  local tool_use_id = msg.tool_use_id
  local elapsed = msg.elapsed_time_seconds
  if tool_use_id and elapsed then
    self.output:update_tool_elapsed(tool_use_id, elapsed)
  end
end

function Router:_handle_control_request(msg)
  local req = msg.request
  if not req then return end
  if req.subtype == 'can_use_tool' then
    self:_handle_permission_request(msg.request_id, req)
  elseif req.subtype == 'elicitation' then
    require('cc.interactive').handle_elicitation(
      self.process, self.output, msg.request_id, req)
  end
end

function Router:_handle_permission_request(request_id, req)
  local tool_name = req.tool_name or 'unknown'
  local input = req.input
  local tool_use_id = req.tool_use_id

  -- Specialized handlers for interactive CC features.
  if tool_name == 'EnterPlanMode' then
    require('cc.interactive').handle_enter_plan_mode(
      self.process, self.output, request_id, req)
    return
  elseif tool_name == 'ExitPlanMode' then
    require('cc.interactive').handle_exit_plan_mode(
      self.process, self.output, request_id, req)
    return
  elseif tool_name == 'AskUserQuestion' then
    require('cc.interactive').handle_ask_user_question(
      self.process, self.output, request_id, req)
    return
  end

  self.output:render_permission_request(tool_name, input)

  vim.ui.select(
    { 'Allow', 'Deny', 'Always Allow (session)' },
    {
      prompt = 'Tool permission: ' .. tool_name,
      format_item = function(item) return item end,
    },
    function(choice)
      if not choice then choice = 'Deny' end
      local behavior = 'deny'
      local response_body
      if choice == 'Allow' or choice == 'Always Allow (session)' then
        behavior = 'allow'
        response_body = {
          behavior = 'allow',
          updatedInput = input,
          toolUseID = tool_use_id,
        }
      else
        response_body = {
          behavior = 'deny',
          message = 'User denied via cc.nvim',
          toolUseID = tool_use_id,
        }
      end
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
    end
  )
end

M.Router = Router
return M
