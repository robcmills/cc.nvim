local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

-- Fake instances with real buffers. `_G.mk(opts)` registers one and returns
-- it; `_G.set(inst, state)` drives its state through statusline.refresh, the
-- path every real transition takes; `_G.link(child, parent)` links them the
-- way `agents new` does.
local SETUP = [==[
  local cc = require('cc')
  local D = require('cc.delegation')
  _G.events = {}
  vim.api.nvim_create_autocmd('User', {
    group = vim.api.nvim_create_augroup('delegation_spec', { clear = true }),
    pattern = 'CcStateChanged',
    callback = function(ev) table.insert(_G.events, ev.data) end,
  })
  function _G.mk(opts)
    opts = opts or {}
    local output_bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local session = require('cc.session').new()
    session.id = opts.session_id or ('sid-' .. output_bufnr)
    local alive = true
    local inst = {
      session = session,
      provider = { name = 'claude', send = function() end },
      process = {
        pid = 4242,
        is_alive = function() return alive end,
        close = function() alive = false end,
      },
      output = {
        bufnr = output_bufnr,
        follow_tail = function() end,
        render_user_turn = function() end,
      },
      prompt = { bufnr = prompt_bufnr },
      cwd = '/tmp',
    }
    inst._kill = function() alive = false end
    cc._register_test_instance(output_bufnr, inst)
    require('cc.statusline').refresh(inst)
    return inst
  end
  function _G.set(inst, state)
    inst.awaiting_input = state == 'waiting'
    inst.session.turn_active = state == 'working'
    require('cc.statusline').refresh(inst)
  end
  function _G.address(inst)
    return { key = D.key(inst), socket = vim.v.servername, bufnr = inst.output.bufnr,
      session_id = inst.session.id }
  end
  function _G.link(child, parent)
    return D.link(child, _G.address(parent))
  end
  function _G.state(inst) return require('cc.instance_state').get(inst) end
]==]

local function setup()
  _G.child.lua(SETUP)
end

local function lua(code, args) return _G.child.lua(code, args) end
local function get(expr) return _G.child.lua_get(expr) end

T['state'] = MiniTest.new_set()

T['state']['two children finishing in either order'] = function()
  setup()
  for _, order in ipairs({ { 'a', 'b' }, { 'b', 'a' } }) do
    lua([[
      _G.p = _G.mk(); _G.a = _G.mk(); _G.b = _G.mk()
      _G.link(_G.a, _G.p); _G.link(_G.b, _G.p)
      _G.set(_G.a, 'working'); _G.set(_G.b, 'working')
    ]])
    eq(get('_G.state(_G.p)'), 'delegating')
    eq(get('require("cc.delegation").busy_count(_G.p)'), 2)
    lua('_G.set(_G.' .. order[1] .. ', "ready")')
    eq(get('_G.state(_G.p)'), 'delegating')
    lua('_G.set(_G.' .. order[2] .. ', "ready")')
    eq(get('_G.state(_G.p)'), 'ready')
  end
end

T['state']['starting and waiting children count as busy; the link outlives idle turns'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk({ session_id = '' })
    _G.c.session.id = nil
    require('cc.statusline').refresh(_G.c)
    _G.link(_G.c, _G.p)
  ]])
  eq(get('_G.state(_G.c)'), 'starting')
  eq(get('_G.state(_G.p)'), 'delegating')
  lua([[_G.c.session.id = 'sid-c'; _G.set(_G.c, 'ready')]])
  eq(get('_G.state(_G.p)'), 'ready')
  -- Re-engaged later (SendMessage, agents send, or Rob typing): busy again.
  lua([[_G.set(_G.c, 'waiting')]])
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['state']['precedence: working and waiting win, delegating beats monitoring and unread'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk()
    _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.set(_G.p, 'working')
  ]])
  eq(get('_G.state(_G.p)'), 'working')
  eq(get('require("cc").list_instances()[1].delegateCount'), 1)
  lua([[
    _G.set(_G.p, 'ready')
    _G.p.session.background_task_count = function() return 1 end
    require('cc.seen').mark_unread(_G.p)
  ]])
  eq(get('_G.state(_G.p)'), 'delegating')
  lua([[_G.set(_G.c, 'ready')]])
  eq(get('_G.state(_G.p)'), 'monitoring')
end

T['state']['fires CcStateChanged on the parent'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p)
    _G.events = {}
    _G.set(_G.c, 'working'); _G.set(_G.c, 'ready')
    _G.parent_events = vim.tbl_map(function(e) return e.state end,
      vim.tbl_filter(function(e) return e.bufnr == _G.p.output.bufnr end, _G.events))
  ]])
  eq(get('_G.parent_events'), { 'delegating', 'ready' })
end

T['state']['nested: a delegating child keeps its parent delegating'] = function()
  setup()
  lua([[
    _G.top = _G.mk(); _G.mid = _G.mk(); _G.leaf = _G.mk()
    _G.link(_G.mid, _G.top); _G.link(_G.leaf, _G.mid)
    _G.set(_G.mid, 'working'); _G.set(_G.leaf, 'working')
    _G.set(_G.mid, 'ready')
  ]])
  eq(get('_G.state(_G.mid)'), 'delegating')
  eq(get('_G.state(_G.top)'), 'delegating')
  lua([[_G.set(_G.leaf, 'ready')]])
  eq(get('_G.state(_G.mid)'), 'ready')
  eq(get('_G.state(_G.top)'), 'ready')
end

T['push'] = MiniTest.new_set()

T['push']['ignores duplicate and out-of-order snapshots'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p)
    local D = require('cc.delegation')
    local function snap(state, seq)
      return { parent_bufnr = _G.p.output.bufnr, key = D.key(_G.c), uid = D.uid(_G.c),
        session_id = 'sid-c', state = state, seq = seq }
    end
    local base = _G.c.delegation_seq
    _G.r1 = D.receive(snap('working', base + 2))
    _G.r2 = D.receive(snap('ready', base + 1))  -- arrives late: older
    _G.r3 = D.receive(snap('working', base + 2)) -- duplicate
  ]])
  eq(get('{ _G.r1, _G.r2, _G.r3 }'), { true, false, false })
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['push']['rejects self-links and cycles, keeps an existing owner'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.a = _G.mk(); _G.b = _G.mk(); _G.other = _G.mk()
    _G.self_ok, _G.self_err = _G.link(_G.a, _G.a)
    _G.link(_G.b, _G.a)
    _G.cycle_ok, _G.cycle_err = _G.link(_G.a, _G.b)
    _G.owner_ok = _G.link(_G.b, _G.other)
    _G.owner = _G.b.delegator.key == D.key(_G.a)
    _G.send_ok = require('cc').send_prompt(_G.b.output.bufnr, 'hi', { delegator = _G.address(_G.other) })
  ]])
  eq(get('{ _G.self_ok, _G.self_err }'), { false, 'an agent cannot delegate to itself' })
  eq(get('{ _G.cycle_ok, _G.cycle_err }'), { false, 'link would make a cycle' })
  eq(get('_G.owner_ok'), false)
  eq(get('_G.owner'), true)
  eq(get('_G.send_ok'), true)
  eq(get('_G.b.delegator.key == require("cc.delegation").key(_G.a)'), true)
end

T['push']['send_prompt links an unlinked instance before its turn starts'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk()
    _G.ok = require('cc').send_prompt(_G.c.output.bufnr, 'go', { delegator = _G.address(_G.p) })
  ]])
  eq(get('_G.ok'), true)
  eq(get('_G.state(_G.c)'), 'working')
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['push']['detach releases the link and a later link registers again'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.d1 = { D.detach_bufnr(_G.c.output.bufnr) }
    _G.after_detach = _G.state(_G.p)
    _G.link(_G.c, _G.p)
  ]])
  eq(get('_G.d1'), { true })
  eq(get('_G.after_detach'), 'ready')
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['clear'] = MiniTest.new_set()

T['clear']['closing a busy child clears the parent'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.before = _G.state(_G.p)
    require('cc').close(_G.c.output.bufnr)
  ]])
  eq(get('_G.before'), 'delegating')
  eq(get('_G.state(_G.p)'), 'ready')
  eq(get('vim.tbl_count(_G.p.delegates)'), 0)
end

T['clear']['process exit clears the parent'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.c._kill()
    _G.c.session.turn_active = false
    require('cc.statusline').refresh(_G.c)
  ]])
  eq(get('_G.state(_G.c)'), 'exited')
  eq(get('_G.state(_G.p)'), 'ready')
end

T['clear']['VimLeavePre releases every linked child'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    require('cc.delegation').release(_G.c)
  ]])
  eq(get('_G.state(_G.p)'), 'ready')
end

T['reconcile'] = MiniTest.new_set()

T['reconcile']['list_instances prunes a child whose Neovim pid is dead, keeps an EPERM one'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk()
    -- Beyond any real pid: kill(pid, 0) fails with ESRCH.
    local dead, perm = 99999999, 1
    for _, pid in ipairs({ dead, perm }) do
      D.receive({ parent_bufnr = _G.p.output.bufnr, key = pid .. ':5', uid = 'u' .. pid,
        nvim_pid = pid, state = 'working', seq = 1 })
    end
    _G.before = D.busy_count(_G.p)
    _G.listed = require('cc').list_instances()[1].delegateCount
  ]])
  eq(get('_G.before'), 2)
  eq(get('_G.listed'), 1)
  eq(get('vim.tbl_keys(_G.p.delegates)'), { '1:5' })
  -- The pruning check is scheduled, then the parent stays delegating on pid 1.
  lua('vim.wait(0)')
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['reconcile']['instance_state.get never probes liveness'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk()
    D.receive({ parent_bufnr = _G.p.output.bufnr, key = '99999999:5', uid = 'u',
      nvim_pid = 99999999, state = 'working', seq = 1 })
    for _ = 1, 3 do require('cc.statusline').refresh(_G.p) end
  ]])
  eq(get('_G.state(_G.p)'), 'delegating')
  eq(get('vim.tbl_count(_G.p.delegates)'), 1)
end

T['reconcile']['buffer number reuse: a new child at the same key retires the old one'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.old = _G.mk()
    _G.link(_G.old, _G.p); _G.set(_G.old, 'working')
    local bufnr, old_key, old_uid = _G.old.output.bufnr, D.key(_G.old), D.uid(_G.old)
    -- The old child vanishes without a word (its exited push was lost).
    _G.old.delegator = nil
    require('cc')._reset_instances()
    require('cc')._register_test_instance(_G.p.output.bufnr, _G.p)
    -- Same buffer number, new incarnation, idle, linked to the same parent.
    _G.new = _G.mk({ bufnr = bufnr, session_id = 'sid-new' })
    _G.link(_G.new, _G.p)
    _G.after_new = _G.state(_G.p)
    -- A late push from the old incarnation must not revive it.
    _G.late = D.receive({ parent_bufnr = _G.p.output.bufnr, key = old_key, uid = old_uid,
      state = 'working', seq = 99 })
  ]])
  eq(get('_G.after_new'), 'ready')
  eq(get('_G.late'), false)
  eq(get('_G.state(_G.p)'), 'ready')
  eq(get('_G.p.delegates[next(_G.p.delegates)].session_id'), 'sid-new')
end

T['reconcile']['a local child replaced at the same buffer is pruned on render'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.old = _G.mk()
    _G.link(_G.old, _G.p); _G.set(_G.old, 'working')
    local bufnr = _G.old.output.bufnr
    _G.old.delegator = nil
    require('cc')._reset_instances()
    require('cc')._register_test_instance(_G.p.output.bufnr, _G.p)
    _G.mk({ bufnr = bufnr })  -- unlinked newcomer at the old buffer number
    _G.count = require('cc').list_instances()
  ]])
  eq(get('vim.tbl_count(_G.p.delegates)'), 0)
end

T['reconcile']['the parent turn boundary pings children, repairing a lost push'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    -- The child's `ready` push is lost.
    local delegator = _G.c.delegator
    _G.c.delegator = nil
    _G.set(_G.c, 'ready')
    _G.c.delegator = delegator
    _G.stuck = _G.state(_G.p)
    -- Jarvis wakes (turn start) and finishes (turn end).
    _G.set(_G.p, 'working')
    _G.set(_G.p, 'ready')
  ]])
  eq(get('_G.stuck'), 'delegating')
  eq(get('_G.state(_G.p)'), 'ready')
end

T['reconcile']['a ping for a child its Neovim no longer has prunes it'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk()
    D.receive({ parent_bufnr = _G.p.output.bufnr, key = vim.fn.getpid() .. ':9999', uid = 'gone',
      nvim_pid = vim.fn.getpid(), bufnr = 9999, state = 'working', seq = 1 })
    _G.before = _G.state(_G.p)
    D.answer_ping({ bufnr = 9999, uid = 'gone', key = vim.fn.getpid() .. ':9999', parent = _G.address(_G.p) })
  ]])
  eq(get('_G.before'), 'delegating')
  eq(get('_G.state(_G.p)'), 'ready')
end

T['reconcile']['agents CLI entry points: repush, prune, rebind'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.p2 = _G.mk({ session_id = 'sid-p' }); _G.c = _G.mk()
    _G.link(_G.c, _G.p)
    _G.set(_G.c, 'working')
    _G.r = { D.repush_bufnr(_G.c.output.bufnr) }
    _G.pr = { D.prune_bufnr(_G.p.output.bufnr, D.key(_G.c), D.uid(_G.c)) }
    _G.after_prune = _G.state(_G.p)
    _G.rb = { D.rebind_bufnr(_G.c.output.bufnr, _G.address(_G.p2)) }
  ]])
  eq(get('_G.r'), { true })
  eq(get('_G.pr'), { true })
  eq(get('_G.after_prune'), 'ready')
  eq(get('_G.rb'), { true })
  eq(get('_G.state(_G.p2)'), 'delegating')
  eq(get('_G.state(_G.p)'), 'ready')
end

T['list_instances'] = MiniTest.new_set()

T['list_instances']['exposes delegateCount, children, and delegator'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    local by = {}
    for _, s in ipairs(require('cc').list_instances()) do by[s.outputBufnr] = s end
    _G.ps, _G.cs = by[_G.p.output.bufnr], by[_G.c.output.bufnr]
    _G.json = vim.json.encode(_G.cs)
  ]])
  eq(get('_G.ps.state'), 'delegating')
  eq(get('_G.ps.delegateCount'), 1)
  eq(get('_G.ps.children[1].state'), 'working')
  eq(get('_G.ps.children[1].key == require("cc.delegation").key(_G.c)'), true)
  eq(get('_G.cs.delegator.key == require("cc.delegation").key(_G.p)'), true)
  eq(get('_G.cs.delegateCount'), 0)
  eq(get('type(_G.json)'), 'string')
end

-- Two real Neovims: the push travels over the parent's socket.
T['cross-neovim'] = MiniTest.new_set()

T['cross-neovim']['a child in another Neovim pushes over rpcnotify'] = function()
  setup()
  local other = helpers.new_child()
  local ok, err = pcall(function()
    other.lua(SETUP)
    other.lua([[_G.p = _G.mk()]])
    local parent = other.lua_get('_G.address(_G.p)')
    lua('_G.c = _G.mk(); _G.parent_addr = ...', { parent })
    lua([[require('cc.delegation').link(_G.c, _G.parent_addr); _G.set(_G.c, 'working')]])
    other.lua([[vim.wait(2000, function() return _G.state(_G.p) == 'delegating' end, 10)]])
    eq(other.lua_get('_G.state(_G.p)'), 'delegating')
    lua([[_G.set(_G.c, 'ready')]])
    other.lua([[vim.wait(2000, function() return _G.state(_G.p) == 'ready' end, 10)]])
    eq(other.lua_get('_G.state(_G.p)'), 'ready')
    -- Close in the child Neovim: the exited push arrives before teardown.
    lua([[_G.set(_G.c, 'working')]])
    other.lua([[vim.wait(2000, function() return _G.state(_G.p) == 'delegating' end, 10)]])
    lua([[require('cc').close(_G.c.output.bufnr)]])
    other.lua([[vim.wait(2000, function() return _G.state(_G.p) == 'ready' end, 10)]])
    eq(other.lua_get('_G.state(_G.p)'), 'ready')
  end)
  other.stop()
  if not ok then error(err, 0) end
end

return T
