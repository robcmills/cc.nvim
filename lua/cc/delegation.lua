-- Delegation: a parent agent shows `delegating` while a child it owns is busy.
--
-- The parent owns the link. The `agents` CLI registers each child here
-- (`register_bufnr`) and installs a forwarder in the child's Neovim: an
-- autocmd on `User CcStateChanged` that rpcnotifies this module's `receive`
-- with the child's state and a sequence number. The child's cc.nvim needs no
-- delegation code, so a child on an older cc.nvim is tracked too.
--
-- Parent state, in memory only:
--   inst.delegates[child_key] = { session_id, nvim_pid, socket, bufnr, state, seq }
--
-- Nothing runs on a clock. Pushes arrive on child transitions. Gaps are
-- repaired during activity that already happens: list_instances (sidebar
-- render and `agents` inventory) drops children whose Neovim has died, the
-- parent's own turn start and end ask its children's forwarders to push
-- again, and every `agents` inventory compares both sides.

local M = {}

--- Child states that keep a parent delegating. A child that is itself
--- delegating counts, so nesting composes when the child runs this code.
M.BUSY = {
  starting = true, working = true, waiting = true,
  interrupting = true, monitoring = true, delegating = true,
}

---@type table<string, integer> socket path -> rpc channel
local channels = {}

local function null_to_nil(value)
  if value == vim.NIL then return nil end
  return value
end

local function self_pid()
  return vim.fn.getpid()
end

local function session_id(inst)
  local sid = inst.last_session_id or (inst.session and inst.session.id)
  if type(sid) ~= 'string' or sid == '' then return nil end
  return sid
end

--- The instance whose output buffer is `bufnr`, if any.
---@param bufnr integer
---@return cc.Instance?
local function output_instance(bufnr)
  if type(bufnr) ~= 'number' then return nil end
  local inst = require('cc').find_instance(bufnr)
  if inst and inst.output and inst.output.bufnr == bufnr then return inst end
  return nil
end

--- The `agents` CLI key of an instance: `<nvim-pid>:<output-bufnr>`.
---@param inst cc.Instance
---@return string
function M.key(inst)
  return self_pid() .. ':' .. inst.output.bufnr
end

local function pid_of_key(key)
  return tonumber(tostring(key):match('^(%d+):'))
end

-- ---------------------------------------------------------------------------
-- Registration (the `agents` CLI calls these over --remote-expr)
-- ---------------------------------------------------------------------------

--- Register a child with the parent at `bufnr`. An existing entry keeps its
--- last pushed state but restarts its sequence: a forwarder installed in a
--- restarted Neovim (same key by pid reuse) counts from 1 again. The
--- forwarder install that follows pushes the child's real state.
---@param bufnr integer parent output bufnr
---@param child { key: string, socket: string?, nvim_pid: integer?, bufnr: integer?, session_id: string?, state: string? }
---@return boolean ok
---@return string? err
function M.register_bufnr(bufnr, child)
  local parent = output_instance(bufnr)
  if not parent then return false, 'no cc.nvim instance owns buffer ' .. tostring(bufnr) end
  if type(child) ~= 'table' then return false, 'child must be a table' end
  local key = null_to_nil(child.key)
  if type(key) ~= 'string' or not key:match('^%d+:%d+$') then
    return false, 'child key must be <nvim-pid>:<output-bufnr>'
  end
  if key == M.key(parent) then return false, 'an agent cannot delegate to itself' end
  parent.delegates = parent.delegates or {}
  local entry = parent.delegates[key] or {}
  entry.seq = -1
  entry.socket = null_to_nil(child.socket) or entry.socket
  entry.nvim_pid = null_to_nil(child.nvim_pid) or entry.nvim_pid or pid_of_key(key)
  entry.bufnr = null_to_nil(child.bufnr) or entry.bufnr or tonumber(key:match(':(%d+)$'))
  entry.session_id = null_to_nil(child.session_id) or entry.session_id
  if not entry.state then
    local state = null_to_nil(child.state)
    entry.state = type(state) == 'string' and state or 'starting'
  end
  parent.delegates[key] = entry
  require('cc.state_events').check(parent)
  return true
end

--- Drop a child from the parent at `bufnr` (detach, or a prune by the
--- `agents` inventory on positive evidence the child is gone).
---@param bufnr integer parent output bufnr
---@param child_key string
---@return boolean ok
---@return string? err
function M.unregister_bufnr(bufnr, child_key)
  local parent = output_instance(bufnr)
  if not parent then return false, 'no cc.nvim instance owns buffer ' .. tostring(bufnr) end
  if parent.delegates and parent.delegates[child_key] then
    parent.delegates[child_key] = nil
    require('cc.state_events').check(parent)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Receiving forwarder pushes
-- ---------------------------------------------------------------------------

--- Entry point for a forwarder's rpcnotify. Runs on the next loop iteration
--- so autocmds and API calls are safe.
function M._remote(method, arg)
  vim.schedule(function()
    if method == 'receive' then pcall(M.receive, arg) end
  end)
end

--- Store a child's pushed state and recompute this parent's state. Only
--- registered children are accepted, so a late push after detach cannot
--- recreate a link. A child that exits or closes leaves the map.
---@param p { parent_bufnr: integer, parent_session_id: string?, key: string, state: string, seq: number, session_id: string? }
---@return boolean applied
---@return string? why
function M.receive(p)
  if type(p) ~= 'table' or type(p.key) ~= 'string' or type(p.state) ~= 'string'
      or type(p.seq) ~= 'number' then
    return false, 'invalid payload'
  end
  local parent = output_instance(p.parent_bufnr)
  if not parent then return false, 'no parent at buffer ' .. tostring(p.parent_bufnr) end
  local expected = null_to_nil(p.parent_session_id)
  local actual = session_id(parent)
  if expected and actual and expected ~= actual then
    return false, 'parent buffer now holds another session'
  end
  local entry = parent.delegates and parent.delegates[p.key]
  if not entry then return false, 'not registered' end
  if p.seq <= entry.seq then return false, 'stale' end
  if p.state == 'exited' then
    parent.delegates[p.key] = nil
  else
    entry.state = p.state
    entry.seq = p.seq
    entry.session_id = null_to_nil(p.session_id) or entry.session_id
  end
  require('cc.state_events').check(parent)
  return true
end

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

--- Busy children. Reads memory only: safe on the spinner path.
---@param inst cc.Instance?
---@return integer
function M.busy_count(inst)
  local count = 0
  for _, entry in pairs(inst and inst.delegates or {}) do
    if M.BUSY[entry.state] then count = count + 1 end
  end
  return count
end

--- JSON-safe child list for list_instances, sorted by key.
---@param inst cc.Instance
---@return table[]
function M.children(inst)
  local list = {}
  for key, entry in pairs(inst.delegates or {}) do
    list[#list + 1] = {
      key = key,
      sessionId = entry.session_id or vim.NIL,
      state = entry.state,
      nvimPid = entry.nvim_pid or vim.NIL,
    }
  end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

-- ---------------------------------------------------------------------------
-- Repair on activity
-- ---------------------------------------------------------------------------

--- Is the child behind `entry` provably gone? A child in this Neovim must
--- still have its instance. A remote child's Neovim must not have exited:
--- `kill(pid, 0)` failing with anything but ESRCH (such as EPERM) counts
--- as alive.
local function gone(entry)
  if entry.nvim_pid == self_pid() then return output_instance(entry.bufnr) == nil end
  if type(entry.nvim_pid) ~= 'number' then return false end
  local ok, _, name = (vim.uv or vim.loop).kill(entry.nvim_pid, 0)
  return not ok and name == 'ESRCH'
end

--- Drop children that are provably gone. Runs only during real activity
--- (list_instances and the parent's turn boundary), never from
--- instance_state.get or statusline.refresh, which the spinner timer calls.
---@param inst cc.Instance
---@return boolean changed
function M.reconcile(inst)
  if not inst or not inst.delegates or not next(inst.delegates) then return false end
  local changed = false
  for key, entry in pairs(inst.delegates) do
    if gone(entry) then
      inst.delegates[key] = nil
      changed = true
    end
  end
  if changed then
    vim.schedule(function() require('cc.state_events').check(inst) end)
  end
  return changed
end

-- The forwarder defines this global in the child's Neovim.
local REPUSH_LUA = 'local f = _G.cc_delegation_repush if f then f(...) end'

local function channel(socket)
  if channels[socket] then return channels[socket] end
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', socket, { rpc = true })
  if not ok or type(chan) ~= 'number' or chan <= 0 then return nil end
  channels[socket] = chan
  return chan
end

--- Fire-and-forget rpcnotify. A cached channel the peer has closed fails
--- once; it is dropped and the message goes out on a fresh connection.
local function notify(socket, code, args)
  for _ = 1, 2 do
    local chan = channel(socket)
    if not chan then return false end
    if pcall(vim.rpcnotify, chan, 'nvim_exec_lua', code, args) then return true end
    channels[socket] = nil
    pcall(vim.fn.chanclose, chan)
  end
  return false
end

--- Ask every child's forwarder to push its current state again. A child in
--- this Neovim is asked directly.
---@param inst cc.Instance
function M.ping_children(inst)
  if not inst.delegates or not inst.output then return end
  M.reconcile(inst)
  local parent_key = M.key(inst)
  local local_done = false
  for _, entry in pairs(inst.delegates) do
    if entry.nvim_pid == self_pid() then
      if not local_done and type(_G.cc_delegation_repush) == 'function' then
        pcall(_G.cc_delegation_repush, parent_key)
        local_done = true
      end
    elseif entry.socket then
      notify(entry.socket, REPUSH_LUA, { parent_key })
    end
  end
end

--- Called by state_events.check after it fires CcStateChanged. A parent
--- whose turn starts or ends pings its children, so a lost push is
--- corrected when the parent next acts.
---@param inst cc.Instance
---@param state string
---@param previous string?
function M.on_state_changed(inst, state, previous)
  if previous and (state == 'working') ~= (previous == 'working')
      and inst.delegates and next(inst.delegates) then
    M.ping_children(inst)
  end
end

--- Test-only: forget cached channels.
function M._reset()
  for socket, chan in pairs(channels) do
    pcall(vim.fn.chanclose, chan)
    channels[socket] = nil
  end
end

return M
