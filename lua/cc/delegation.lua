-- Delegation: a parent agent shows `delegating` while a child it is linked
-- to is busy.
--
-- The link lives in memory only, in both instances:
--   child:  inst.delegator = { key, socket, bufnr, session_id } (where to push)
--   parent: inst.delegates[child_key] = { uid, session_id, nvim_pid, socket,
--           bufnr, state, seq } (what each child last pushed)
--
-- State travels as pushes, never on a clock. The child pushes a full
-- snapshot from state_events.check on every transition (rpcnotify over a
-- cached socket channel, or a direct call when both share this Neovim). The
-- parent stores it and re-runs state_events.check on itself, which fires its
-- own CcStateChanged. Snapshots carry a per-incarnation uid and a sequence
-- number, so duplicates and late arrivals are ignored and any later push
-- heals a lost one.
--
-- Gaps (a crashed Neovim, a lost message) are repaired during activity that
-- already happens: list_instances (sidebar render and `agents` inventory)
-- checks child liveness, and the parent's turn start and end ask every child
-- to push again. The `agents` CLI does the cross-Neovim comparison.

local M = {}

--- Child states that keep a parent delegating. A child that is itself
--- delegating counts, so nesting composes.
M.BUSY = {
  starting = true, working = true, waiting = true,
  interrupting = true, monitoring = true, delegating = true,
}

-- Larger than any real sequence number; marks an incarnation as gone for good.
local FINAL_SEQ = 2 ^ 53

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

--- A random id for this instance's lifetime. Buffer numbers are reused
--- after a wipe, so the key alone cannot tell two incarnations apart.
---@param inst cc.Instance
---@return string
function M.uid(inst)
  if not inst.delegation_uid then
    inst.delegation_uid = string.format('%x-%x-%06x', self_pid(),
      (vim.uv or vim.loop).hrtime(), math.random(0, 0xffffff))
  end
  return inst.delegation_uid
end

local function pid_of_key(key)
  return tonumber(key:match('^(%d+):'))
end

local function is_local(key)
  return pid_of_key(key) == self_pid()
end

--- Validate a parent address from an RPC caller (JSON nulls arrive as vim.NIL).
---@param ref table?
---@return table? delegator
---@return string? err
function M.normalize(ref)
  if type(ref) ~= 'table' then return nil, 'delegator must be a table' end
  local key = null_to_nil(ref.key)
  if type(key) ~= 'string' or not key:match('^%d+:%d+$') then
    return nil, 'delegator key must be <nvim-pid>:<output-bufnr>'
  end
  local bufnr = null_to_nil(ref.bufnr)
  if type(bufnr) ~= 'number' then bufnr = tonumber(key:match(':(%d+)$')) end
  local socket = null_to_nil(ref.socket)
  local sid = null_to_nil(ref.session_id)
  return {
    key = key,
    bufnr = bufnr,
    socket = type(socket) == 'string' and socket ~= '' and socket or nil,
    session_id = type(sid) == 'string' and sid ~= '' and sid or nil,
  }
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------

local REMOTE_LUA = "return require('cc.delegation')._remote(...)"

local function channel(socket)
  if channels[socket] then return channels[socket] end
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', socket, { rpc = true })
  if not ok or type(chan) ~= 'number' or chan <= 0 then return nil end
  channels[socket] = chan
  return chan
end

--- Deliver `method(arg)` to the Neovim that owns `key`: a direct call when
--- that is this Neovim, else a fire-and-forget rpcnotify. Never waits on the
--- peer. A cached channel the peer has closed fails once; it is dropped and
--- the message goes out on a fresh connection. Any other loss is repaired by
--- the next push or reconciliation.
---@param key string
---@param socket string?
---@param method string
---@param arg table
---@return boolean sent
function M.send(key, socket, method, arg)
  if is_local(key) then
    local ok = pcall(M._dispatch, method, arg)
    return ok
  end
  if not socket then return false end
  for _ = 1, 2 do
    local chan = channel(socket)
    if not chan then return false end
    if pcall(vim.rpcnotify, chan, 'nvim_exec_lua', REMOTE_LUA, { method, arg }) then
      return true
    end
    channels[socket] = nil
    pcall(vim.fn.chanclose, chan)
  end
  return false
end

--- Entry point for rpcnotify from another Neovim. Runs on the next loop
--- iteration so autocmds and API calls are safe.
function M._remote(method, arg)
  vim.schedule(function() pcall(M._dispatch, method, arg) end)
end

function M._dispatch(method, arg)
  if method == 'receive' then return M.receive(arg) end
  if method == 'repush' then return M.answer_ping(arg) end
  error('cc.delegation: unknown method ' .. tostring(method))
end

-- ---------------------------------------------------------------------------
-- Child side
-- ---------------------------------------------------------------------------

---@param inst cc.Instance
---@param state string
---@return table
local function payload(inst, state)
  local d = inst.delegator
  inst.delegation_seq = (inst.delegation_seq or 0) + 1
  return {
    parent_bufnr = d.bufnr,
    parent_session_id = d.session_id,
    key = M.key(inst),
    uid = M.uid(inst),
    session_id = session_id(inst),
    nvim_pid = self_pid(),
    socket = vim.v.servername,
    bufnr = inst.output.bufnr,
    state = state,
    seq = inst.delegation_seq,
  }
end

--- Push this instance's state (default: its current state) to its parent.
---@param inst cc.Instance
---@param state string?
---@return boolean sent
function M.push(inst, state)
  local d = inst and inst.delegator
  if not d or not inst.output then return false end
  state = state or require('cc.instance_state').get(inst)
  return M.send(d.key, d.socket, 'receive', payload(inst, state))
end

--- Walk up from `parent_key` through local delegators. True when the chain
--- reaches `child_key`. Remote hops are checked by the `agents` CLI, which
--- sees every Neovim.
local function local_cycle(parent_key, child_key)
  local seen = {}
  local key = parent_key
  while key and not seen[key] do
    if key == child_key then return true end
    seen[key] = true
    if not is_local(key) then return false end
    local inst = output_instance(tonumber(key:match(':(%d+)$')))
    key = inst and inst.delegator and inst.delegator.key or nil
  end
  return false
end

--- Link `inst` to a parent and push its current state there. An existing
--- owner is kept unless `opts.replace`: each child has a single parent.
---@param inst cc.Instance
---@param ref table parent address { key, socket, bufnr, session_id }
---@param opts { replace: boolean? }?
---@return boolean linked true when `inst` ends up linked to this parent
---@return string? err
function M.link(inst, ref, opts)
  if not inst or not inst.output then return false, 'no cc.nvim instance' end
  local parent, err = M.normalize(ref)
  if not parent then return false, err end
  local key = M.key(inst)
  if parent.key == key then return false, 'an agent cannot delegate to itself' end
  local current = inst.delegator
  if current and current.key == parent.key and not (opts and opts.replace) then
    return true
  end
  if current and not (opts and opts.replace) then
    return false, 'already linked to ' .. current.key
  end
  if local_cycle(parent.key, key) then return false, 'link would make a cycle' end
  if current and current.key ~= parent.key then M.push(inst, 'detached') end
  inst.delegator = parent
  M.push(inst)
  return true
end

--- Release `inst` from its parent.
---@param inst cc.Instance
---@return boolean ok
---@return string? err
function M.detach(inst)
  if not inst or not inst.delegator then return false, 'not linked to a parent' end
  M.push(inst, 'detached')
  inst.delegator = nil
  return true
end

--- Tell the parent this instance is gone. Called before teardown removes
--- the instance data that addresses the parent.
---@param inst cc.Instance
function M.release(inst)
  if inst and inst.delegator and inst.output then pcall(M.push, inst, 'exited') end
end

--- A parent's ping: push again, or report that the child it names is gone.
---@param arg { bufnr: integer, uid: string?, key: string, parent: table }
function M.answer_ping(arg)
  local parent = M.normalize(arg.parent)
  if not parent then return false end
  local inst = output_instance(arg.bufnr)
  local uid = null_to_nil(arg.uid)
  if inst and (not uid or inst.delegation_uid == uid)
      and inst.delegator and inst.delegator.key == parent.key then
    return M.push(inst)
  end
  if inst and uid and inst.delegation_uid == uid then
    -- The child left this parent. Ordered with its own pushes, so linking
    -- back later still registers.
    inst.delegation_seq = (inst.delegation_seq or 0) + 1
    return M.send(parent.key, parent.socket, 'receive', {
      parent_bufnr = parent.bufnr, key = arg.key, uid = uid,
      state = 'detached', seq = inst.delegation_seq,
    })
  end
  -- This Neovim answered without that child: it is gone for good.
  return M.send(parent.key, parent.socket, 'receive', {
    parent_bufnr = parent.bufnr, key = arg.key, uid = uid,
    state = 'exited', seq = FINAL_SEQ,
  })
end

-- ---------------------------------------------------------------------------
-- Parent side
-- ---------------------------------------------------------------------------

local function release_uid(inst, uid, seq)
  if not uid then return end
  inst.delegate_released = inst.delegate_released or {}
  local current = inst.delegate_released[uid]
  if not current or seq > current then inst.delegate_released[uid] = seq end
end

--- Store a child's pushed snapshot and recompute this parent's state.
---@param p table payload from `payload()`
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
  local uid = null_to_nil(p.uid)
  local released = uid and parent.delegate_released and parent.delegate_released[uid]
  if released and p.seq <= released then return false, 'stale' end
  parent.delegates = parent.delegates or {}
  local current = parent.delegates[p.key]
  if current and current.uid == uid and current.seq >= p.seq then return false, 'stale' end
  if current and current.uid ~= uid then
    -- A new incarnation at a reused buffer number retires the old one.
    release_uid(parent, current.uid, FINAL_SEQ)
  end
  if p.state == 'exited' or p.state == 'detached' then
    release_uid(parent, uid, p.state == 'exited' and FINAL_SEQ or p.seq)
    if current and current.uid == uid then parent.delegates[p.key] = nil end
  else
    parent.delegates[p.key] = {
      uid = uid,
      session_id = null_to_nil(p.session_id),
      nvim_pid = null_to_nil(p.nvim_pid) or pid_of_key(p.key),
      socket = null_to_nil(p.socket),
      bufnr = null_to_nil(p.bufnr),
      state = p.state,
      seq = p.seq,
    }
  end
  require('cc.state_events').check(parent)
  return true
end

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
      uid = entry.uid or vim.NIL,
    }
  end
  table.sort(list, function(a, b) return a.key < b.key end)
  return list
end

--- JSON-safe parent address for list_instances, or vim.NIL.
---@param inst cc.Instance
function M.delegator_ref(inst)
  local d = inst.delegator
  if not d then return vim.NIL end
  return {
    key = d.key,
    sessionId = d.session_id or vim.NIL,
    socket = d.socket or vim.NIL,
    bufnr = d.bufnr or vim.NIL,
  }
end

--- Is the child behind `entry` provably gone? A local child must still be
--- registered with the same uid. A remote child's Neovim must not have
--- exited: `kill(pid, 0)` failing with anything but ESRCH (such as EPERM)
--- counts as alive.
local function gone(entry)
  if entry.nvim_pid == self_pid() then
    local child = output_instance(entry.bufnr)
    return not child or (entry.uid ~= nil and child.delegation_uid ~= entry.uid)
  end
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
      release_uid(inst, entry.uid, FINAL_SEQ)
      inst.delegates[key] = nil
      changed = true
    end
  end
  if changed then
    vim.schedule(function() require('cc.state_events').check(inst) end)
  end
  return changed
end

--- Ask every linked child to push its current state. A child whose Neovim
--- answers without it reports it gone.
---@param inst cc.Instance
function M.ping_children(inst)
  if not inst.delegates or not inst.output then return end
  M.reconcile(inst)
  local parent = {
    key = M.key(inst), socket = vim.v.servername,
    bufnr = inst.output.bufnr, session_id = session_id(inst),
  }
  for key, entry in pairs(inst.delegates) do
    M.send(key, entry.socket, 'repush', {
      bufnr = entry.bufnr, uid = entry.uid, key = key, parent = parent,
    })
  end
end

--- Called by state_events.check after it fires CcStateChanged. A child
--- pushes the new state; a parent whose turn starts or ends pings its
--- children so a lost push is corrected when the parent next acts.
---@param inst cc.Instance
---@param state string
---@param previous string?
function M.on_state_changed(inst, state, previous)
  if inst.delegator then M.push(inst, state) end
  if previous and (state == 'working') ~= (previous == 'working')
      and inst.delegates and next(inst.delegates) then
    M.ping_children(inst)
  end
end

-- ---------------------------------------------------------------------------
-- RPC entry points for the `agents` CLI (by output bufnr)
-- ---------------------------------------------------------------------------

function M.detach_bufnr(bufnr)
  local inst = output_instance(bufnr)
  if not inst then return false, 'no cc.nvim instance owns buffer ' .. tostring(bufnr) end
  return M.detach(inst)
end

function M.repush_bufnr(bufnr)
  local inst = output_instance(bufnr)
  if not inst then return false, 'no cc.nvim instance owns buffer ' .. tostring(bufnr) end
  if not inst.delegator then return false, 'not linked to a parent' end
  return M.push(inst)
end

--- Drop one child entry, only if it is still the incarnation `uid`.
function M.prune_bufnr(bufnr, child_key, uid)
  local inst = output_instance(bufnr)
  if not inst then return false, 'no cc.nvim instance owns buffer ' .. tostring(bufnr) end
  uid = null_to_nil(uid)
  local entry = inst.delegates and inst.delegates[child_key]
  if entry and (not uid or entry.uid == uid) then
    -- Block only pushes this old; a child linked back later registers again.
    release_uid(inst, entry.uid, entry.seq)
    inst.delegates[child_key] = nil
    require('cc.state_events').check(inst)
  end
  return true
end

--- Point a child at its parent's new address and push.
function M.rebind_bufnr(bufnr, ref)
  local inst = output_instance(bufnr)
  if not inst then return false, 'no cc.nvim instance owns buffer ' .. tostring(bufnr) end
  return M.link(inst, ref, { replace = true })
end

--- Test-only: forget cached channels.
function M._reset()
  for socket, chan in pairs(channels) do
    pcall(vim.fn.chanclose, chan)
    channels[socket] = nil
  end
end

return M
