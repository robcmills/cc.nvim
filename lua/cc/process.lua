-- Persistent claude CLI subprocess manager.
-- Uses vim.uv.spawn() to get direct access to stdin/stdout/stderr pipes.
-- All pipe callbacks are wrapped in vim.schedule() for thread safety.

local uv = vim.uv or vim.loop
local Command = require('cc.command')
local Parser = require('cc.parser')

local M = {}

---@class cc.Process
---@field opts table
---@field handle userdata?
---@field pid integer?
---@field stdin userdata?
---@field stdout userdata?
---@field stderr userdata?
---@field parser cc.Parser
---@field on_message fun(msg: table)
---@field on_stderr fun(data: string)?
---@field on_exit fun(code: integer, signal: integer)?
---@field alive boolean
---@field _tee_fd userdata? file descriptor for NDJSON dump
---@field _pending_controls table<string, { subtype: string, callback: function? }> request id -> metadata
local Process = {}
Process.__index = Process

--- Generate a v4-ish uuid. Good enough for local correlation of control_request
--- request_ids; not cryptographic.
---@return string
local function gen_uuid()
  local function h(n) return string.format('%0' .. n .. 'x', math.random(0, 16 ^ n - 1)) end
  return h(8) .. '-' .. h(4) .. '-4' .. h(3) .. '-' .. h(4) .. '-' .. h(8) .. h(4)
end

---@param opts { cmd: string, cwd: string?, session_id: string?, permission_mode: string?, model: string?, effort: string?, extra_args: string[]?, on_message: fun(msg: table), on_stderr: fun(data: string)?, on_exit: fun(code: integer, signal: integer)? }
function M.new(opts)
  return setmetatable({
    opts = opts,
    parser = Parser.new(),
    on_message = opts.on_message,
    on_stderr = opts.on_stderr,
    on_exit = opts.on_exit,
    alive = false,
    _pending_controls = {},
  }, Process)
end

function Process:spawn()
  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  local args = {
    '-p',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--permission-prompt-tool', 'stdio',
    '--include-partial-messages',
    '--include-hook-events',
    '--verbose',
    '--append-system-prompt', table.concat({
      'You are running inside a Neovim chat UI (cc.nvim). The user reads your replies as chat messages and types answers in a prompt buffer.',
      'Do not use the AskUserQuestion tool. If you need input from the user, ask directly in your reply as prose; the user will answer in their next message.',
      'Do not use EnterPlanMode or ExitPlanMode. If you want to propose a plan before acting, write the plan inline in your reply and wait for the user to respond.',
      'When the user phrases a prompt as a question (e.g., "Would it be more robust to...?", "What if we...?", "Should I...?", "Could we...?", "I wonder if..."), respond with analysis or explanation only. Do not make code changes, edits, or implementations. Wait for an explicit directive like "go ahead", "make that change", "do it", or "yes, update it" before editing any files. This applies even in auto mode.',
    }, ' '),
  }

  if self.opts.session_id then
    table.insert(args, '--resume')
    table.insert(args, self.opts.session_id)
  end
  if self.opts.permission_mode then
    table.insert(args, '--permission-mode')
    table.insert(args, self.opts.permission_mode)
  end
  if self.opts.model then
    table.insert(args, '--model')
    table.insert(args, self.opts.model)
  end
  for _, a in ipairs(self.opts.extra_args or {}) do
    table.insert(args, a)
  end

  local executable, resolved_args = Command.resolve(self.opts.cmd, args)
  local handle, pid = uv.spawn(executable, {
    args = resolved_args,
    stdio = { self.stdin, self.stdout, self.stderr },
    cwd = self.opts.cwd or vim.fn.getcwd(),
    -- A process-level effort pin cannot be changed by the live
    -- apply_flag_settings control request. Explicitly remove it and let the
    -- provider seed effort over stdin after spawn.
    env = require('cc.effort').runtime_env(),
  }, function(code, signal)
    vim.schedule(function()
      self.alive = false
      if self.on_exit then
        self.on_exit(code, signal)
      end
    end)
  end)

  if not handle then
    local err = pid
    self:_cleanup_pipes()
    error('cc.nvim: failed to spawn claude: ' .. tostring(err))
  end

  self.handle = handle
  self.pid = pid
  self.alive = true

  self.stdout:read_start(function(err, data)
    if err then
      vim.schedule(function()
        vim.notify('cc.nvim: stdout read error: ' .. err, vim.log.levels.ERROR)
      end)
      return
    end
    if data then
      -- Tee raw bytes to dump file if active
      if self._tee_fd then
        uv.fs_write(self._tee_fd, data)
      end
      local messages = self.parser:feed(data)
      if #messages > 0 then
        vim.schedule(function()
          for _, msg in ipairs(messages) do
            self.on_message(msg)
          end
        end)
      end
    end
  end)

  self.stderr:read_start(function(err, data)
    if data and self.on_stderr then
      vim.schedule(function()
        self.on_stderr(data)
      end)
    end
    if err then
      vim.schedule(function()
        vim.notify('cc.nvim: stderr read error: ' .. err, vim.log.levels.WARN)
      end)
    end
  end)

  return true
end

--- Write an NDJSON message to stdin.
---@param msg table
function Process:write(msg)
  if not self.alive or not self.stdin then
    vim.notify('cc.nvim: process not alive; cannot write', vim.log.levels.WARN)
    return
  end
  local line = vim.json.encode(msg) .. '\n'
  self.stdin:write(line, function(err)
    if err then
      vim.schedule(function()
        vim.notify('cc.nvim: stdin write error: ' .. err, vim.log.levels.ERROR)
      end)
    end
  end)
end

--- Send SIGINT for graceful interruption of current turn.
function Process:interrupt()
  if self.alive and self.pid then
    uv.kill(self.pid, 'sigint')
  end
end

---@param subtype string
---@param request table
---@param callback fun(ok: boolean, response: table?)?
---@return string?
function Process:_send_control(subtype, request, callback)
  if not self.alive or not self.stdin then return nil end
  local request_id = gen_uuid()
  self._pending_controls[request_id] = {
    subtype = subtype,
    callback = callback,
  }
  self:write({
    type = 'control_request',
    request_id = request_id,
    request = request,
  })
  return request_id
end

--- Send a stream-json control_request to interrupt the current turn without
--- killing the CLI process. The CLI aborts the in-flight API stream and any
--- running tool, then returns a control_response with the same request_id.
--- Returns the request_id so callers can correlate the response, or nil if
--- the process is not alive.
---@return string?
function Process:send_control_interrupt()
  return self:_send_control('interrupt', { subtype = 'interrupt' })
end

--- Send a stream-json control_request to change the live session's
--- permission mode. The CLI applies the new mode and echoes it back in the
--- next system/init message (which updates session.permission_mode). Returns
--- the request_id so callers can correlate the response, or nil if the
--- process is not alive.
---@param mode string one of: acceptEdits, auto, bypassPermissions, default, dontAsk, plan
---@return string?
function Process:send_control_set_permission_mode(mode)
  return self:_send_control(
    'set_permission_mode',
    { subtype = 'set_permission_mode', mode = mode })
end

--- Change the model used for subsequent turns.
---@param model string
---@param callback fun(ok: boolean, response: table?)?
---@return string?
function Process:send_control_set_model(model, callback)
  return self:_send_control(
    'set_model',
    { subtype = 'set_model', model = model },
    callback)
end

--- Change the live effort setting. `auto` clears the flag-settings override,
--- allowing the CLI's normal settings/model resolution to choose the value.
---@param effort string
---@param callback fun(ok: boolean, response: table?)?
---@return string?
function Process:send_control_set_effort(effort, callback)
  local value = effort == 'auto' and vim.NIL or effort
  return self:_send_control(
    'set_effort',
    { subtype = 'apply_flag_settings', settings = { effort = value } },
    callback)
end

--- Send a stream-json control_request to read the CLI's effective settings
--- (the merge of user/project/local/policy settings.json files). Used at
--- session startup to discover the resolved `permissions.defaultMode`
--- before the user's first prompt triggers an init message. Returns the
--- request_id, or nil if the process is not alive.
---@return string?
function Process:send_control_get_settings()
  return self:_send_control('get_settings', { subtype = 'get_settings' })
end

--- Consume a pending control_request record by id.
---@param request_id string
---@return { subtype: string, callback: function? }?
function Process:consume_pending_control_entry(request_id)
  local entry = self._pending_controls[request_id]
  if entry then self._pending_controls[request_id] = nil end
  return entry
end

--- Backwards-compatible subtype-only consumer used by tests/integrations.
---@param request_id string
---@return string?
function Process:consume_pending_control(request_id)
  local entry = self:consume_pending_control_entry(request_id)
  return entry and entry.subtype or nil
end

--- Terminate the process.
function Process:close()
  if self.alive and self.pid then
    uv.kill(self.pid, 'sigterm')
  end
  self:_cleanup_pipes()
  self.alive = false
end

function Process:_cleanup_pipes()
  for _, pipe in ipairs({ self.stdin, self.stdout, self.stderr }) do
    if pipe and not pipe:is_closing() then
      pipe:close()
    end
  end
  self.stdin, self.stdout, self.stderr = nil, nil, nil
end

function Process:is_alive()
  return self.alive
end

--- Start tee-ing raw stdout bytes to a file.
---@param path string
function Process:start_dump(path)
  if self._tee_fd then
    self:stop_dump()
  end
  local fd, err = uv.fs_open(path, 'w', 438) -- 0666
  if not fd then
    vim.notify('cc.nvim: failed to open dump file: ' .. tostring(err), vim.log.levels.ERROR)
    return
  end
  self._tee_fd = fd
  vim.notify('cc.nvim: dumping NDJSON to ' .. path, vim.log.levels.INFO)
end

--- Stop tee-ing and close the dump file.
function Process:stop_dump()
  if self._tee_fd then
    uv.fs_close(self._tee_fd)
    self._tee_fd = nil
    vim.notify('cc.nvim: NDJSON dump stopped', vim.log.levels.INFO)
  end
end

return M
