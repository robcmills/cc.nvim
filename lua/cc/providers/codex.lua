-- Codex provider: drives `codex app-server` (newline-delimited JSON-RPC)
-- behind the provider interface. Transport, request correlation, approval
-- responses, and thread-item → render translation all live here; shared UI
-- code (output.lua, session.lua, statusline.lua) never sees Codex wire
-- messages.
--
-- Protocol reference: `codex app-server generate-json-schema --out <dir>`
-- (v2 method names: initialize, thread/start, thread/resume, turn/start,
-- turn/interrupt, thread/list, thread/name/set, item/* notifications).
-- Verified against codex-cli 0.144.5.

local Config = require('cc.config')
local Parser = require('cc.parser')

local uv = vim.uv or vim.loop

local M = {}

M.name = 'codex'

---@type cc.ProviderCapabilities
M.capabilities = {
  permission_modes = false,
  effort = true,
  cost_usd = false,
  slash_commands = false,
  auto_rename = true,
  local_history = false,
  plan_mode = false,
}

--- Effective codex options from Config.options.providers.codex.
---@return { approval_policy: string?, auto_rename_model: string, cmd: string, effort: string, extra_args: string[], model: string, sandbox: string? }
function M.options()
  local p = (Config.options.providers or {}).codex or {}
  return {
    approval_policy = p.approval_policy,
    auto_rename_model = p.auto_rename_model or 'gpt-5.6-luna',
    cmd = p.cmd or 'codex',
    effort = p.effort or 'medium',
    extra_args = p.extra_args or {},
    model = p.model or 'gpt-5.6-sol',
    sandbox = p.sandbox,
  }
end

-- cc /effort levels → codex reasoning efforts. Codex has no 'max'; 'auto'
-- means "don't send an override" (nil).
local EFFORT_MAP = {
  low = 'low', medium = 'medium', high = 'high', xhigh = 'xhigh', max = 'xhigh',
}

---@class cc.CodexProvider
---@field name string
---@field capabilities cc.ProviderCapabilities
---@field opts table resolved M.options() plus ctx flags
---@field instance cc.Instance?
---@field session cc.Session?
---@field output cc.Output?
---@field resume_id string?
---@field thread_id string?
---@field turn_id string?
---@field alive boolean
---@field pending table<integer, fun(result: table?, err: table?)> request id -> callback
---@field items table<string, table> item id -> live render state
local Codex = {}
Codex.__index = Codex

--- Build a Codex provider instance wired to one cc.Instance.
--- With ctx.headless, no session/output is required and no thread is
--- started after initialize — used by list_history's one-shot client.
---@param ctx cc.ProviderCtx|{ headless: boolean? }
---@return cc.CodexProvider
function M.attach(ctx)
  local opts = M.options()
  if ctx.model ~= nil then opts.model = ctx.model end
  if ctx.effort ~= nil then opts.effort = ctx.effort end
  opts.cwd = vim.fn.getcwd()
  local self = setmetatable({
    name = M.name,
    capabilities = M.capabilities,
    opts = opts,
    instance = ctx.instance,
    session = ctx.session,
    output = ctx.output,
    resume_id = ctx.resume_id,
    on_session_id = ctx.on_session_id,
    on_exit = ctx.on_exit,
    headless = ctx.headless or false,
    alive = false,
    parser = Parser.new(),
    next_request_id = 0,
    pending = {},
    items = {},
    _open_prose = nil, -- { item_id, kind = 'text'|'thinking', streamed = n }
    _queued_sends = {},
  }, Codex)
  return self
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------

function Codex:spawn()
  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  local args = { 'app-server' }
  for _, a in ipairs(self.opts.extra_args) do
    table.insert(args, a)
  end

  local handle, pid = uv.spawn(self.opts.cmd, {
    args = args,
    stdio = { self.stdin, self.stdout, self.stderr },
    cwd = self.opts.cwd or vim.fn.getcwd(),
  }, function(code, signal)
    vim.schedule(function()
      self.alive = false
      self:_fail_pending('codex app-server exited')
      if self.on_exit then self.on_exit(code, signal) end
    end)
  end)

  if not handle then
    local err = pid
    self:_cleanup_pipes()
    error('cc.nvim: failed to spawn codex app-server: ' .. tostring(err))
  end

  self.handle = handle
  self.pid = pid
  self.alive = true

  self.stdout:read_start(function(err, data)
    if err then
      vim.schedule(function()
        vim.notify('cc.nvim: codex stdout read error: ' .. err, vim.log.levels.ERROR)
      end)
      return
    end
    if data then
      if self._tee_fd then uv.fs_write(self._tee_fd, data) end
      local messages = self.parser:feed(data)
      if #messages > 0 then
        vim.schedule(function()
          for _, msg in ipairs(messages) do
            self:_on_message(msg)
          end
        end)
      end
    end
  end)

  -- codex app-server logs (tracing) go to stderr; surface only on abnormal
  -- exit rather than notifying per-line, which would be noisy.
  self._stderr_tail = {}
  self.stderr:read_start(function(_, data)
    if data then
      table.insert(self._stderr_tail, data)
      if #self._stderr_tail > 20 then table.remove(self._stderr_tail, 1) end
    end
  end)

  self:_start_protocol()
end

--- Handshake: initialize → initialized → thread/start | thread/resume.
--- Split from spawn() so tests can drive the protocol with a stubbed
--- transport (override _write_line, feed replies via _on_message).
function Codex:_start_protocol()
  self:request('initialize', {
    clientInfo = {
      name = 'cc.nvim',
      title = 'cc.nvim',
      version = require('cc').VERSION,
    },
  }, function(_, err)
    if err then
      self:_notify_error('initialize failed', err)
      return
    end
    self:notify('initialized')
    if self.headless then
      if self.on_ready then self.on_ready() end
      return
    end
    if self.resume_id then
      local params = { threadId = self.resume_id }
      if self.opts.approval_policy then params.approvalPolicy = self.opts.approval_policy end
      if self.opts.sandbox then params.sandbox = self.opts.sandbox end
      self:request('thread/resume', params, function(result, rerr)
        if rerr then
          self:_notify_error('thread/resume failed', rerr)
          return
        end
        self:_on_thread_ready(result, true)
      end)
    else
      local params = { cwd = self.opts.cwd or vim.fn.getcwd() }
      if self.opts.approval_policy then params.approvalPolicy = self.opts.approval_policy end
      if self.opts.sandbox then params.sandbox = self.opts.sandbox end
      self:request('thread/start', params, function(result, serr)
        if serr then
          self:_notify_error('thread/start failed', serr)
          return
        end
        self:_on_thread_ready(result, false)
      end)
    end
  end)
end

--- Write one JSON line to the subprocess. Tests override this.
---@param line string
function Codex:_write_line(line)
  if not self.alive or not self.stdin then
    vim.notify('cc.nvim: codex app-server not alive; cannot write', vim.log.levels.WARN)
    return
  end
  self.stdin:write(line .. '\n', function(err)
    if err then
      vim.schedule(function()
        vim.notify('cc.nvim: codex stdin write error: ' .. err, vim.log.levels.ERROR)
      end)
    end
  end)
end

---@param obj table
function Codex:_write(obj)
  self:_write_line(vim.json.encode(obj))
end

--- Send a JSON-RPC request; cb receives (result, error).
---@param method string
---@param params table?
---@param cb fun(result: table?, err: table?)?
---@return integer request_id
function Codex:request(method, params, cb)
  self.next_request_id = self.next_request_id + 1
  local id = self.next_request_id
  if cb then self.pending[id] = cb end
  local msg = { jsonrpc = '2.0', id = id, method = method }
  if params ~= nil then msg.params = params end
  self:_write(msg)
  return id
end

--- Send a JSON-RPC notification.
---@param method string
---@param params table?
function Codex:notify(method, params)
  local msg = { jsonrpc = '2.0', method = method }
  if params ~= nil then msg.params = params end
  self:_write(msg)
end

--- Respond to a server-initiated request.
---@param id any JSON-RPC id from the server request (preserved verbatim)
---@param result table
function Codex:respond(id, result)
  self:_write({ jsonrpc = '2.0', id = id, result = result })
end

---@param id any
---@param code integer
---@param message string
function Codex:respond_error(id, code, message)
  self:_write({ jsonrpc = '2.0', id = id, error = { code = code, message = message } })
end

--- Dispatch one decoded JSON-RPC message from the server.
---@param msg table
function Codex:_on_message(msg)
  if type(msg) ~= 'table' then return end
  if msg.method ~= nil then
    if msg.id ~= nil then
      self:_on_server_request(msg)
    else
      self:_on_notification(msg.method, msg.params or {})
    end
    return
  end
  if msg.id ~= nil then
    local cb = self.pending[msg.id]
    self.pending[msg.id] = nil
    if cb then cb(msg.result, msg.error) end
  end
end

function Codex:_fail_pending(reason)
  local pending = self.pending
  self.pending = {}
  for _, cb in pairs(pending) do
    pcall(cb, nil, { code = -1, message = reason })
  end
end

---@param prefix string
---@param err table?
function Codex:_notify_error(prefix, err)
  local detail = err and (err.message or vim.inspect(err)) or 'unknown error'
  vim.notify('cc.nvim [codex]: ' .. prefix .. ': ' .. detail, vim.log.levels.ERROR)
  if self.output then
    self.output:render_notice('codex: ' .. prefix)
  end
end

function Codex:is_alive()
  return self.alive
end

function Codex:close()
  if self.alive and self.pid then
    uv.kill(self.pid, 'sigterm')
  end
  self:_cleanup_pipes()
  self.alive = false
  self.pending = {}
end

function Codex:_cleanup_pipes()
  for _, pipe in ipairs({ self.stdin, self.stdout, self.stderr }) do
    if pipe and not pipe:is_closing() then
      pipe:close()
    end
  end
  self.stdin, self.stdout, self.stderr = nil, nil, nil
end

--- Tee raw stdout bytes to a file (fixture capture, :CcDumpNdjson).
---@param path string
function Codex:start_dump(path)
  if self._tee_fd then self:stop_dump() end
  local fd, err = uv.fs_open(path, 'w', 438)
  if not fd then
    vim.notify('cc.nvim: failed to open dump file: ' .. tostring(err), vim.log.levels.ERROR)
    return
  end
  self._tee_fd = fd
  vim.notify('cc.nvim: dumping codex JSON-RPC to ' .. path, vim.log.levels.INFO)
end

function Codex:stop_dump()
  if self._tee_fd then
    uv.fs_close(self._tee_fd)
    self._tee_fd = nil
    vim.notify('cc.nvim: dump stopped', vim.log.levels.INFO)
  end
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------

local restore_rollout_commands

---@param result table thread/start or thread/resume response
---@param resumed boolean
function Codex:_on_thread_ready(result, resumed)
  local thread = result.thread or {}
  self.thread_id = thread.id
  local s = self.session
  if s then
    s.id = thread.id
    s.model = result.model or s.model
    if type(result.reasoningEffort) == 'string' and result.reasoningEffort ~= '' then
      s.resolved_effort = result.reasoningEffort
    end
    s.permission_mode = M._mode_string(result)
  end
  if thread.name and thread.name ~= '' and self.instance then
    self.instance.session_name = thread.name
    pcall(function() require('cc')._apply_session_buf_names(self.instance, thread.name) end)
  end
  if resumed and self.output then
    restore_rollout_commands(thread)
    self:_replay_turns(thread.turns or {})
    self.output:render_notice('resumed ' .. tostring(thread.id):sub(1, 8))
  end
  if self.on_session_id and thread.id then
    self.on_session_id(thread.id)
  end
  if self.instance then
    pcall(function() require('cc')._flush_pending_rename(self.instance) end)
  end
  self:_refresh()
  -- Flush prompts submitted before the thread was ready.
  local queued = self._queued_sends
  self._queued_sends = {}
  for _, text in ipairs(queued) do
    self:send(text)
  end
end

--- Compact statusline "mode" for codex: approval policy / sandbox type.
---@param result table thread/start-shaped response
---@return string?
function M._mode_string(result)
  local approval = result.approvalPolicy
  if type(approval) == 'table' then approval = 'granular' end
  local sandbox = result.sandbox
  if type(sandbox) == 'table' then sandbox = sandbox.type end
  if approval and sandbox then return approval .. '/' .. sandbox end
  return approval or sandbox
end

---@param text string
function Codex:send(text)
  if not self.thread_id then
    table.insert(self._queued_sends, text)
    return
  end
  local params = {
    threadId = self.thread_id,
    input = { { type = 'text', text = text } },
  }
  if self.opts.model then params.model = self.opts.model end
  local effort = self:_effort()
  if effort then params.effort = effort end
  self:request('turn/start', params, function(result, err)
    if err then
      self:_notify_error('turn/start failed', err)
      if self.session then
        self.session.turn_active = false
        self.session.is_streaming = false
      end
      self:_refresh()
      return
    end
    if result and result.turn then
      self.turn_id = result.turn.id
    end
  end)
end

--- Codex reasoning effort for the next turn: explicit provider config wins,
--- else the /effort level (mapped; 'auto' → nil so codex uses its default).
---@return string?
function Codex:_effort()
  return EFFORT_MAP[self.opts.effort]
end

---@param model string
---@param cb fun(ok: boolean, err: string?)?
---@return boolean
function Codex:set_model(model, cb)
  self.opts.model = model
  if self.session then
    self.session.model = model
    self.session.context_window = nil
  end
  self:_refresh()
  if cb then cb(true) end
  return true
end

---@param effort string
---@param cb fun(ok: boolean, err: string?)?
---@return boolean
function Codex:set_effort(effort, cb)
  self.opts.effort = effort
  if self.session then
    self.session.resolved_effort = EFFORT_MAP[effort]
  end
  self:_refresh()
  if cb then cb(true) end
  return true
end

--- Request interruption of the active turn. Truthy when the request was
--- sent; the turn/completed notification (status=interrupted) renders the
--- outcome.
---@return boolean?
function Codex:interrupt()
  if not (self.alive and self.thread_id and self.turn_id) then return nil end
  self:request('turn/interrupt', {
    threadId = self.thread_id,
    turnId = self.turn_id,
  }, function(_, err)
    if err then
      if self.session then self.session.interrupt_pending = false end
      self:_notify_error('interrupt failed', err)
      self:_refresh()
    end
  end)
  return true
end

--- Rename the thread via thread/name/set.
---@param name string
---@param cb fun(ok: boolean, err: string?)?
---@return boolean sent
function Codex:rename(name, cb)
  if not (self.alive and self.thread_id) then
    if cb then cb(false, 'no active codex thread') end
    return false
  end
  self:request('thread/name/set', { threadId = self.thread_id, name = name }, function(_, err)
    if cb then cb(err == nil, err and err.message or nil) end
  end)
  return true
end

--- Build an isolated one-shot `codex exec` command used by auto-rename.
--- `--ephemeral` keeps the helper turn out of thread history; the final
--- message file avoids mixing Codex progress output with the title.
---@param prompt string
---@param cfg table
---@return table
function Codex:auto_rename_spec(prompt, _cfg)
  local output_path = vim.fn.tempname()
  local args = {
    'exec',
    '--ephemeral',
    '--sandbox', 'read-only',
    '--skip-git-repo-check',
    '--ignore-rules',
    '--color', 'never',
    '--output-last-message', output_path,
  }
  local model = self.opts.auto_rename_model or self.opts.model
  if type(model) == 'string' and model ~= '' then
    table.insert(args, '--model')
    table.insert(args, model)
  end
  table.insert(args, prompt)
  return {
    cmd = self.opts.cmd,
    args = args,
    output_path = output_path,
    cleanup = function()
      if (vim.uv or vim.loop).fs_stat(output_path) then
        pcall((vim.uv or vim.loop).fs_unlink, output_path)
      end
    end,
  }
end

function Codex:_refresh()
  if self.instance then
    pcall(function()
      require('cc.statusline_spinner').sync(self.instance)
      require('cc.statusline').refresh(self.instance)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Notifications → session state + rendering
-- ---------------------------------------------------------------------------

---@param method string
---@param params table
function Codex:_on_notification(method, params)
  if not self.output or not self.session then return end
  if method == 'turn/started' then
    self:_on_turn_started(params)
  elseif method == 'turn/completed' then
    self:_on_turn_completed(params)
  elseif method == 'item/started' then
    self:_on_item_started(params.item or {})
  elseif method == 'item/completed' then
    self:_on_item_completed(params.item or {})
  elseif method == 'item/agentMessage/delta' or method == 'item/plan/delta' then
    self:_on_text_delta(params.itemId, params.delta, 'text')
  elseif method == 'item/reasoning/summaryTextDelta'
      or method == 'item/reasoning/textDelta' then
    self:_on_text_delta(params.itemId, params.delta, 'thinking')
  elseif method == 'item/reasoning/summaryPartAdded' then
    if self._open_prose and self._open_prose.kind == 'thinking' then
      self.output:on_delta('thinking', '\n\n')
    end
  elseif method == 'thread/tokenUsage/updated' then
    self:_on_token_usage(params)
  elseif method == 'turn/plan/updated' then
    self.output:render_plan(params.plan or {}, params.explanation)
  elseif method == 'thread/compacted' then
    self.output:render_notice('Context Compacted')
  elseif method == 'thread/name/updated' then
    if self.instance and type(params.name) == 'string' and params.name ~= '' then
      self.instance.session_name = params.name
      pcall(function() require('cc')._apply_session_buf_names(self.instance, params.name) end)
      self:_refresh()
    end
  elseif method == 'error' then
    local err = params.error or {}
    local text = 'Error: ' .. tostring(err.message or 'unknown')
    if params.willRetry then text = text .. ' (retrying)' end
    self.output:render_notice(text)
  elseif method == 'warning' or method == 'deprecationNotice' or method == 'configWarning' then
    local text = params.message or (params.notice and params.notice.message)
    if text then self.output:render_notice('codex: ' .. tostring(text)) end
  end
  -- Everything else (thread/status/changed, account/*, mcpServer/*, fs/*,
  -- realtime, fuzzyFileSearch, …) is intentionally a no-op.
end

function Codex:_on_turn_started(params)
  local s = self.session
  local turn = params.turn or {}
  self.turn_id = turn.id or self.turn_id
  s.interrupt_pending = false
  s.turn_active = true
  if not s.turn_started_at then
    s.turn_started_at = uv.now()
  end
  self._turn_usage_base = self._last_total_usage
  self:_refresh()
end

function Codex:_on_turn_completed(params)
  local s = self.session
  local turn = params.turn or {}
  self:_close_prose()
  self.output:stop_all_tool_timers()

  local result = s:finish_turn(turn.durationMs)
  result.usage = self:_turn_usage_delta()

  if turn.status == 'interrupted' then
    self.output:render_interrupted({
      turn_ended_at = result.turn_ended_at,
      turn_elapsed_ms = result.turn_elapsed_ms,
    })
  elseif turn.status == 'failed' then
    local message = turn.error and turn.error.message or 'turn failed'
    self.output:render_notice('Error: ' .. tostring(message))
  else
    self.output:render_result(result)
  end
  self.turn_id = nil
  self:_refresh()
end

--- Map codex cumulative thread usage onto the session's claude-shaped
--- fields. Codex inputTokens INCLUDES cached tokens (totalTokens = input +
--- output, verified live), so the non-cached share is input - cached.
function Codex:_on_token_usage(params)
  local usage = params.tokenUsage or {}
  local total = usage.total or {}
  local last = usage.last or {}
  local s = self.session
  local cached = total.cachedInputTokens or 0
  s.input_tokens = math.max(0, (total.inputTokens or 0) - cached)
  s.output_tokens = total.outputTokens or 0
  s.cache_read_input_tokens = cached
  -- The last API call's full input load approximates live context usage.
  s.context_tokens = last.inputTokens or s.context_tokens
  if type(usage.modelContextWindow) == 'number' and usage.modelContextWindow > 0 then
    s.context_window = usage.modelContextWindow
  end
  self._last_total_usage = {
    input = total.inputTokens or 0,
    cached = cached,
    output = total.outputTokens or 0,
  }
  self:_refresh()
end

--- Per-turn usage: delta of cumulative thread totals across the turn,
--- shaped like an Anthropic usage table for the shared cost-line formatter.
---@return table?
function Codex:_turn_usage_delta()
  local base = self._turn_usage_base or { input = 0, cached = 0, output = 0 }
  local now = self._last_total_usage
  if not now then return nil end
  local function d(a, b) return a > b and (a - b) or 0 end
  local cached = d(now.cached, base.cached)
  return {
    input_tokens = d(d(now.input, base.input), cached),
    output_tokens = d(now.output, base.output),
    cache_read_input_tokens = cached,
  }
end

-- ---------------------------------------------------------------------------
-- Thread items → rendering
-- ---------------------------------------------------------------------------

--- Tool name + input for a non-prose thread item, reusing the shared
--- renderer's per-tool formatting where semantics line up.
---@param item table
---@return string? name, table? input
local function tool_for_item(item)
  local t = item.type
  if t == 'commandExecution' then
    -- Unlike Claude, codex command items do not include a human-written
    -- description. Suppress the shared renderer's command-as-summary fallback
    -- so the full command appears only in the expanded Bash body.
    local input = { command = item.command, _display_summary = false }
    if item.cwd and item.cwd ~= '' and item.cwd ~= vim.fn.getcwd() then
      input.cwd = item.cwd
    end
    return 'Bash', input
  elseif t == 'fileChange' then
    -- Each changed path is already shown above its diff in the expanded body.
    return 'FileChange', { changes = item.changes, _display_summary = false }
  elseif t == 'mcpToolCall' then
    local name = 'mcp__' .. tostring(item.server or '?') .. '__' .. tostring(item.tool or '?')
    return name, item.arguments or {}
  elseif t == 'dynamicToolCall' then
    return tostring(item.tool or 'tool'), item.arguments or {}
  elseif t == 'webSearch' then
    return 'WebSearch', { query = item.query }
  elseif t == 'collabAgentToolCall' then
    return 'Agent', { prompt = item.prompt, model = item.model }
  elseif t == 'imageGeneration' then
    return 'ImageGeneration', { prompt = item.revisedPrompt }
  end
  return nil, nil
end

--- Result text + error flag for a completed tool item.
---@param item table
---@return string text, boolean is_error
local function tool_result_for_item(item)
  local t = item.type
  local failed = item.status == 'failed' or item.status == 'declined'
  if t == 'commandExecution' then
    local text = item.aggregatedOutput or ''
    local suffix = {}
    if type(item.exitCode) == 'number' and item.exitCode ~= 0 then
      table.insert(suffix, 'exit ' .. item.exitCode)
      failed = true
    end
    if item.status == 'declined' then table.insert(suffix, 'declined') end
    if #suffix > 0 then
      text = text ~= '' and (text .. '\n[' .. table.concat(suffix, ', ') .. ']')
        or ('[' .. table.concat(suffix, ', ') .. ']')
    end
    return text, failed
  elseif t == 'mcpToolCall' then
    if item.error then
      return tostring(type(item.error) == 'table' and (item.error.message or vim.inspect(item.error)) or item.error), true
    end
    local r = item.result
    if type(r) == 'table' then
      local parts = {}
      for _, blk in ipairs(r.content or {}) do
        if type(blk) == 'table' and blk.type == 'text' and blk.text then
          table.insert(parts, blk.text)
        end
      end
      if #parts > 0 then return table.concat(parts, '\n'), failed end
      local ok, s = pcall(vim.json.encode, r)
      return ok and s or '', failed
    end
    return tostring(r or ''), failed
  end
  return '', failed
end

--- Extract display text from a userMessage item's content blocks.
---@param item table
---@return string
local function user_message_text(item)
  local parts = {}
  for _, blk in ipairs(item.content or {}) do
    if type(blk) == 'table' then
      if blk.type == 'text' and blk.text then
        table.insert(parts, blk.text)
      elseif blk.type == 'image' or blk.type == 'localImage' then
        table.insert(parts, '[image]')
      elseif blk.type == 'skill' and blk.name then
        table.insert(parts, '/' .. blk.name)
      end
    end
  end
  return table.concat(parts, '\n')
end

--- Close the in-flight text/thinking block, if any.
function Codex:_close_prose()
  if not self._open_prose then return end
  local kind = self._open_prose.kind
  self._open_prose = nil
  self.output:on_content_block_stop({ type = kind })
  self.session.is_streaming = false
end

--- Open a streamed text/thinking block for an item.
---@param item_id string
---@param kind 'text'|'thinking'
function Codex:_open_prose_block(item_id, kind)
  self:_close_prose()
  self.output:begin_assistant_turn()
  self.output:on_content_block_start({ type = kind })
  self.session.is_streaming = true
  self._open_prose = { item_id = item_id, kind = kind, streamed = 0 }
end

---@param item table
function Codex:_on_item_started(item)
  local t = item.type
  if t == 'userMessage' then
    -- Echo of our own turn/start input; already rendered at submit time.
    return
  elseif t == 'agentMessage' or t == 'plan' then
    self:_open_prose_block(item.id, 'text')
  elseif t == 'reasoning' then
    if Config.options.show_thinking then
      self:_open_prose_block(item.id, 'thinking')
    end
  elseif t == 'contextCompaction' then
    self.output:render_notice('Compacting context...')
  elseif t == 'subAgentActivity' then
    self.output:render_task('started', tostring(item.agentPath or item.kind or ''))
  elseif t == 'enteredReviewMode' or t == 'exitedReviewMode' or t == 'sleep'
      or t == 'imageView' or t == 'hookPrompt' then
    return -- no useful progressive rendering
  else
    local name, input = tool_for_item(item)
    if name then
      self:_close_prose()
      self:_start_tool(item.id, name, input, false)
    end
  end
end

---@param item table
function Codex:_on_item_completed(item)
  local t = item.type
  if t == 'userMessage' then
    return
  elseif t == 'agentMessage' or t == 'plan' then
    local open = self._open_prose
    if open and open.item_id == item.id then
      -- item/completed is authoritative: if nothing streamed, render the
      -- final text wholesale rather than dropping it.
      if open.streamed == 0 and type(item.text) == 'string' and item.text ~= '' then
        self.output:on_delta('text', item.text)
      end
      self:_close_prose()
    elseif type(item.text) == 'string' and item.text ~= '' then
      -- Completed without a matching start (missed start or already closed).
      self:_render_prose(item.text, 'text')
    end
  elseif t == 'reasoning' then
    local open = self._open_prose
    if open and open.item_id == item.id then
      self:_close_prose()
    end
  elseif t == 'contextCompaction' then
    self.output:render_notice('Context Compacted')
  elseif t == 'subAgentActivity' then
    self.output:render_task('done', tostring(item.agentPath or item.kind or ''))
  elseif t == 'enteredReviewMode' or t == 'exitedReviewMode' or t == 'sleep'
      or t == 'imageView' or t == 'hookPrompt' then
    return
  else
    local name = tool_for_item(item)
    if not name then return end
    if not self.items[item.id] then
      -- Completed without a start (e.g. instant items): render both halves.
      self:_on_item_started(item)
    end
    local text, is_error = tool_result_for_item(item)
    if text ~= '' or is_error then
      self.output:render_tool_result(item.id, text, is_error)
      self.session:record_tool_result(item.id, text, is_error)
    else
      self.output:stop_tool_timer(item.id)
    end
    self.items[item.id] = nil
  end
end

---@param item_id string?
---@param delta string?
---@param kind 'text'|'thinking'
function Codex:_on_text_delta(item_id, delta, kind)
  if type(delta) ~= 'string' or delta == '' then return end
  if kind == 'thinking' and not Config.options.show_thinking then return end
  local open = self._open_prose
  if not open or open.item_id ~= item_id or open.kind ~= kind then
    self:_open_prose_block(item_id, kind)
    open = self._open_prose
  end
  self.output:on_delta(kind, delta)
  open.streamed = open.streamed + #delta
end

--- Render a complete prose block in one shot (history replay, missed starts).
---@param text string
---@param kind 'text'|'thinking'
function Codex:_render_prose(text, kind)
  if kind == 'thinking' and not Config.options.show_thinking then return end
  self:_close_prose()
  self.output:begin_assistant_turn()
  self.output:on_content_block_start({ type = kind })
  self.output:on_delta(kind, text)
  self.output:on_content_block_stop({ type = kind })
end

--- Restore exec_command calls omitted from app-server's persisted ThreadItem
--- conversion. This matters when resuming a thread created by another Codex
--- surface: the rollout retains response_item function calls, but 0.145's
--- thread/resume response drops them from turn.items.
---@param thread table
restore_rollout_commands = function(thread)
  local path = thread.path
  if type(path) ~= 'string' or path == '' or vim.fn.filereadable(path) ~= 1 then
    return
  end

  local commands_by_turn = {}
  local commands_by_call = {}
  local agent_count_by_turn = {}

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return end
  for _, line in ipairs(lines) do
    local decoded_ok, record = pcall(vim.json.decode, line)
    local payload = decoded_ok and type(record) == 'table'
      and record.type == 'response_item' and record.payload or nil
    if type(payload) == 'table' then
      local metadata = payload.internal_chat_message_metadata_passthrough
      local turn_id = type(metadata) == 'table' and metadata.turn_id or nil
      if payload.type == 'message' and payload.role == 'assistant' and turn_id then
        agent_count_by_turn[turn_id] = (agent_count_by_turn[turn_id] or 0) + 1
      elseif payload.type == 'function_call' and payload.name == 'exec_command'
          and turn_id and payload.call_id then
        local args_ok, args = pcall(vim.json.decode, payload.arguments or '{}')
        local command = args_ok and type(args) == 'table' and args.cmd or nil
        if type(command) == 'string' and command ~= '' then
          local restored = {
            type = 'commandExecution',
            id = 'rollout-' .. tostring(payload.call_id),
            command = command,
            cwd = args.workdir or thread.cwd or '',
            commandActions = {},
            status = 'completed',
            aggregatedOutput = '',
            _after_agent_count = agent_count_by_turn[turn_id] or 0,
          }
          commands_by_turn[turn_id] = commands_by_turn[turn_id] or {}
          table.insert(commands_by_turn[turn_id], restored)
          commands_by_call[payload.call_id] = restored
        end
      elseif payload.type == 'function_call_output' and payload.call_id then
        local restored = commands_by_call[payload.call_id]
        if restored then
          local output = type(payload.output) == 'string' and payload.output or ''
          local exit_code = tonumber(output:match('Process exited with code (%-?%d+)'))
          restored.exitCode = exit_code
          if exit_code and exit_code ~= 0 then restored.status = 'failed' end
          restored.aggregatedOutput = output:match('\nOutput:\n(.*)') or output
        end
      end
    end
  end

  for _, turn in ipairs(thread.turns or {}) do
    local restored = commands_by_turn[turn.id]
    if restored and #restored > 0 then
      local existing = {}
      for _, item in ipairs(turn.items or {}) do
        if item.type == 'commandExecution' and type(item.command) == 'string' then
          existing[item.command] = (existing[item.command] or 0) + 1
        end
      end
      local missing = {}
      for _, item in ipairs(restored) do
        local count = existing[item.command] or 0
        if count > 0 then
          existing[item.command] = count - 1
        else
          table.insert(missing, item)
        end
      end

      if #missing > 0 then
        local merged = {}
        local next_missing = 1
        local seen_agents = 0
        local function insert_due()
          while next_missing <= #missing
              and missing[next_missing]._after_agent_count <= seen_agents do
            missing[next_missing]._after_agent_count = nil
            table.insert(merged, missing[next_missing])
            next_missing = next_missing + 1
          end
        end
        for _, item in ipairs(turn.items or {}) do
          if item.type ~= 'userMessage' then insert_due() end
          table.insert(merged, item)
          if item.type == 'agentMessage' then seen_agents = seen_agents + 1 end
        end
        insert_due()
        while next_missing <= #missing do
          missing[next_missing]._after_agent_count = nil
          table.insert(merged, missing[next_missing])
          next_missing = next_missing + 1
        end
        turn.items = merged
      end
    end
  end
end

--- Render a tool header + input. Codex items carry their full input up
--- front (no streamed input JSON), so start and input render together.
---@param item_id string
---@param name string
---@param input table?
---@param historical boolean
function Codex:_start_tool(item_id, name, input, historical)
  self.output:begin_assistant_turn()
  self.session:begin_tool_call(item_id, name)
  self.output:on_content_block_start({ type = 'tool_use', id = item_id, name = name })
  if not historical then
    self.output:start_tool_timer(item_id)
  end
  self.session:finalize_tool_call(item_id, input)
  self.output:on_content_block_stop(
    { type = 'tool_use', id = item_id, name = name, input = input },
    { historical = historical })
  -- Keep the input around: fileChange approval requests reference the item
  -- by id only, so the prompt needs this to show the diff.
  self.items[item_id] = { name = name, input = input }
end

--- Replay stored turns from a thread/resume (or thread/read) response.
---@param turns table[]
function Codex:_replay_turns(turns)
  local max = Config.options.history_max_records or 200
  local items = {}
  for _, turn in ipairs(turns) do
    for _, item in ipairs(turn.items or {}) do
      table.insert(items, item)
    end
  end
  local start_idx = 1
  if #items > max then
    start_idx = #items - max + 1
    self.output:render_notice(string.format(
      'earlier history hidden (%d records); showing last %d', start_idx - 1, max))
  end
  for i = start_idx, #items do
    self:_replay_item(items[i])
  end
  self:_close_prose()
  self.output.last_turn_role = nil
end

---@param item table
function Codex:_replay_item(item)
  local t = item.type
  if t == 'userMessage' then
    self:_close_prose()
    local text = user_message_text(item)
    if text ~= '' then self.output:render_user_turn(text) end
  elseif t == 'agentMessage' or t == 'plan' then
    if type(item.text) == 'string' and item.text ~= '' then
      self:_render_prose(item.text, 'text')
    end
  elseif t == 'reasoning' then
    local parts = {}
    for _, s in ipairs(item.summary or {}) do
      if type(s) == 'string' and s ~= '' then table.insert(parts, s) end
    end
    if #parts > 0 then
      self:_render_prose(table.concat(parts, '\n\n'), 'thinking')
    end
  elseif t == 'contextCompaction' then
    self.output:render_notice('Context Compacted')
  elseif t == 'subAgentActivity' then
    self.output:render_task('done', tostring(item.agentPath or item.kind or ''))
  elseif t == 'enteredReviewMode' or t == 'exitedReviewMode' or t == 'sleep'
      or t == 'imageView' or t == 'hookPrompt' then
    return
  else
    local name, input = tool_for_item(item)
    if not name then return end
    self:_close_prose()
    self:_start_tool(item.id, name, input, true)
    local text, is_error = tool_result_for_item(item)
    if text ~= '' or is_error then
      self.output:render_tool_result(item.id, text, is_error)
    end
    self.items[item.id] = nil
  end
end

-- ---------------------------------------------------------------------------
-- Server-initiated requests (approvals, user input)
-- ---------------------------------------------------------------------------

---@param msg table JSON-RPC request from the server
function Codex:_on_server_request(msg)
  local method = msg.method
  local params = msg.params or {}
  if method == 'item/commandExecution/requestApproval' then
    self:_approve_command(msg.id, params, false)
  elseif method == 'execCommandApproval' then
    self:_approve_command(msg.id, params, true)
  elseif method == 'item/fileChange/requestApproval' then
    self:_approve_file_change(msg.id, params, false)
  elseif method == 'applyPatchApproval' then
    self:_approve_file_change(msg.id, params, true)
  elseif method == 'item/tool/requestUserInput' then
    self:_request_user_input(msg.id, params)
  else
    -- item/permissions/requestApproval, mcpServer/elicitation/request, and
    -- anything newer: refuse explicitly so the server unblocks rather than
    -- waiting forever on a response we'll never send.
    self:respond_error(msg.id, -32601,
      'cc.nvim does not support server request: ' .. tostring(method))
    if self.output then
      self.output:render_notice('codex request declined (unsupported): ' .. tostring(method))
    end
  end
end

-- v2 CommandExecutionApprovalDecision / legacy ReviewDecision values.
local DECISIONS = {
  v2 = { allow_once = 'accept', allow_always = 'acceptForSession', deny = 'decline' },
  legacy = { allow_once = 'approved', allow_always = 'approved_for_session', deny = 'denied' },
}

---@param behavior 'allow'|'deny'
---@param variant string
---@param legacy boolean
---@return string
local function map_decision(behavior, variant, legacy)
  local set = legacy and DECISIONS.legacy or DECISIONS.v2
  if behavior == 'allow' then
    return variant == 'allow_always' and set.allow_always or set.allow_once
  end
  return set.deny
end

---@param id any JSON-RPC request id
---@param params table
---@param legacy boolean
function Codex:_approve_command(id, params, legacy)
  local input = { command = params.command, _display_summary = false }
  if params.cwd then input.cwd = params.cwd end
  if params.reason then input.reason = params.reason end
  if self.output then
    self.output:render_permission_request('Bash', input)
  end
  require('cc.permission_prompt').ask('Bash', input, function(behavior, variant)
    if self.output then
      self.output:render_permission_outcome(behavior, 'Bash')
    end
    self:respond(id, { decision = map_decision(behavior, variant, legacy) })
  end)
end

---@param id any
---@param params table
---@param legacy boolean
function Codex:_approve_file_change(id, params, legacy)
  -- v2 params carry only ids; look up the pending fileChange item for its
  -- diff. Legacy applyPatchApproval carries fileChanges inline.
  local input = {}
  if params.fileChanges then
    input.changes = params.fileChanges
  else
    local tracked = self.items[params.itemId or '']
    input.changes = tracked and tracked.input and tracked.input.changes or nil
  end
  if params.reason then input.reason = params.reason end
  if self.output then
    self.output:render_permission_request('FileChange', input)
  end
  require('cc.permission_prompt').ask('FileChange', input, function(behavior, variant)
    if self.output then
      self.output:render_permission_outcome(behavior, 'FileChange')
    end
    self:respond(id, { decision = map_decision(behavior, variant, legacy) })
  end)
end

--- EXPERIMENTAL codex request_user_input: walk the questions sequentially
--- with vim.ui.select (options) / vim.ui.input (free text), then respond
--- with the collected answers.
---@param id any
---@param params table
function Codex:_request_user_input(id, params)
  local questions = params.questions or {}
  local answers = {}
  local idx = 0

  local function finish()
    self:respond(id, { answers = answers })
  end

  local function ask_next()
    idx = idx + 1
    local q = questions[idx]
    if not q then
      finish()
      return
    end
    if self.output and q.question then
      self.output:render_notice('Question: ' .. tostring(q.question))
    end
    local options = q.options
    if type(options) == 'table' and #options > 0 then
      local labels = {}
      for _, opt in ipairs(options) do
        table.insert(labels, type(opt) == 'table' and (opt.label or opt.value or '') or tostring(opt))
      end
      vim.ui.select(labels, { prompt = q.question or q.header or 'codex' }, function(choice)
        answers[q.id] = { answers = { choice or '' } }
        ask_next()
      end)
    else
      vim.ui.input({ prompt = (q.question or q.header or 'codex') .. ': ' }, function(text)
        answers[q.id] = { answers = { text or '' } }
        ask_next()
      end)
    end
  end

  ask_next()
end

-- ---------------------------------------------------------------------------
-- History (module-level: one-shot headless client)
-- ---------------------------------------------------------------------------

--- List codex threads via a transient app-server (initialize → thread/list →
--- terminate). Asynchronous; cb receives provider-neutral entries.
---@param opts { all: boolean?, cwd: string?, limit: integer? }?
---@param cb fun(entries: table[])
function M.list_history(opts, cb)
  opts = opts or {}
  local client = M.attach({ headless = true })
  local finished = false
  local function finish(entries)
    if finished then return end
    finished = true
    pcall(function() client:close() end)
    cb(entries)
  end

  client.on_exit = function()
    finish({})
  end
  client.on_ready = function()
    client:request('thread/list', { limit = opts.limit or 200 }, function(result, err)
      if err or not result then
        vim.notify('cc.nvim [codex]: thread/list failed: '
          .. tostring(err and err.message or 'no result'), vim.log.levels.ERROR)
        finish({})
        return
      end
      local cwd = opts.cwd or vim.fn.getcwd()
      local entries = {}
      for _, t in ipairs(result.data or {}) do
        if opts.all or t.cwd == cwd then
          local title = (t.name and t.name ~= '' and t.name)
            or (t.preview and t.preview ~= '' and t.preview:gsub('\n', ' '):sub(1, 120))
            or '(empty)'
          table.insert(entries, {
            session_id = t.id,
            title = title,
            cwd = t.cwd,
            mtime = t.updatedAt or t.createdAt or 0,
            provider = 'codex',
          })
        end
      end
      finish(entries)
    end)
  end

  local ok, err = pcall(function() client:spawn() end)
  if not ok then
    vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    finish({})
  end
end

---@param entry table
---@param show_cwd boolean
---@return string
function M.format_history_entry(entry, show_cwd)
  return require('cc.history').format_entry(entry, show_cwd)
end

--- No local pre-render for codex: history replays from the thread/resume
--- response once the app-server connects.
---@param inst cc.Instance
---@param session_id string
function M.prerender_resume(inst, session_id)
  inst.output:render_notice('resuming ' .. tostring(session_id):sub(1, 8) .. '…')
end

M.Codex = Codex
M._tool_for_item = tool_for_item
M._tool_result_for_item = tool_result_for_item
M._map_decision = map_decision
return M
