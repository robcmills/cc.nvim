-- Find live Claude processes that already hold a session id.
--
-- Every running `claude` writes <config_dir>/sessions/<pid>.json with at
-- least `pid` and `sessionId` (plus `tmux`, `cwd`, `name` on current CLIs).
-- Files outlive crashed processes, so an entry only counts when its pid is
-- alive. Used by :CcResume / :CcHistory to avoid running one session in two
-- processes that both append to the same transcript.

local M = {}

---@class cc.LiveSessionHolder
---@field pid integer
---@field session_id string
---@field cwd string?
---@field name string?
---@field tmux string? `session:@window.%pane` as written by the CLI

---@return string
function M.dir()
  local base = vim.env.CLAUDE_CONFIG_DIR
  if not base or base == '' then base = vim.fn.expand('~/.claude') end
  return base .. '/sessions'
end

--- Signal 0 checks existence without delivering anything. EPERM means the
--- pid exists but belongs to another user, which still counts as alive.
---@param pid integer
---@return boolean
function M.pid_alive(pid)
  if type(pid) ~= 'number' or pid <= 0 then return false end
  local ok, _, name = vim.uv.kill(pid, 0)
  if ok == 0 then return true end
  return name == 'EPERM'
end

---@param path string
---@return table?
local function read_json(path)
  local fd = io.open(path, 'r')
  if not fd then return nil end
  local raw = fd:read('*a')
  fd:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == 'table' then return decoded end
  return nil
end

--- Scan the sessions directory once.
---@return table<string, cc.LiveSessionHolder> holders keyed by session id
function M.scan()
  local holders = {}
  local dir = M.dir()
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return holders end
  while true do
    local fname, ftype = vim.uv.fs_scandir_next(handle)
    if not fname then break end
    if (ftype == 'file' or ftype == nil) and fname:match('^%d+%.json$') then
      local data = read_json(dir .. '/' .. fname)
      local pid = data and tonumber(data.pid)
      local sid = data and data.sessionId
      if pid and type(sid) == 'string' and sid ~= '' and M.pid_alive(pid) then
        holders[sid] = {
          pid = pid,
          session_id = sid,
          cwd = type(data.cwd) == 'string' and data.cwd or nil,
          name = type(data.name) == 'string' and data.name or nil,
          tmux = type(data.tmux) == 'string' and data.tmux or nil,
        }
      end
    end
  end
  return holders
end

---@param session_id string
---@return cc.LiveSessionHolder?
function M.find(session_id)
  return M.scan()[session_id]
end

--- Best-effort tmux location for a `session:@window.%pane` value: one
--- `tmux display-message` call, falling back to the raw value.
---@param tmux string
---@return string
local function tmux_label(tmux)
  local pane = tmux:match('(%%%d+)$')
  if pane and vim.fn.executable('tmux') == 1 then
    local ok, out = pcall(vim.fn.system, { 'tmux', 'display-message', '-p', '-t', pane, '#S:#I #W' })
    if ok and vim.v.shell_error == 0 and type(out) == 'string' then
      out = vim.trim(out)
      if out ~= '' then return out end
    end
  end
  return tmux
end

--- One-line description of where a holder runs.
---@param holder cc.LiveSessionHolder
---@param local_pids table<integer, boolean>? pids spawned by this Neovim
---@return string
function M.describe(holder, local_pids)
  local parts = { 'pid ' .. holder.pid }
  if local_pids and local_pids[holder.pid] then
    table.insert(parts, 'in this Neovim')
  elseif holder.tmux then
    table.insert(parts, 'tmux ' .. tmux_label(holder.tmux))
  end
  if holder.name then table.insert(parts, '"' .. holder.name .. '"') end
  return table.concat(parts, ', ')
end

return M
