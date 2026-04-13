-- Persistent claude CLI subprocess manager.
-- Uses vim.uv.spawn() to get direct access to stdin/stdout/stderr pipes.
-- All pipe callbacks are wrapped in vim.schedule() for thread safety.

local uv = vim.uv or vim.loop
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
local Process = {}
Process.__index = Process

---@param opts { claude_cmd: string, cwd: string?, session_id: string?, permission_mode: string?, model: string?, extra_args: string[]?, on_message: fun(msg: table), on_stderr: fun(data: string)?, on_exit: fun(code: integer, signal: integer)? }
function M.new(opts)
  return setmetatable({
    opts = opts,
    parser = Parser.new(),
    on_message = opts.on_message,
    on_stderr = opts.on_stderr,
    on_exit = opts.on_exit,
    alive = false,
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
    '--include-partial-messages',
    '--include-hook-events',
    '--verbose',
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

  local handle, pid = uv.spawn(self.opts.claude_cmd, {
    args = args,
    stdio = { self.stdin, self.stdout, self.stderr },
    cwd = self.opts.cwd or vim.fn.getcwd(),
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

return M
