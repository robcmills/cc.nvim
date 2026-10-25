-- Cross-session messages the CLI parks (system/peer_message_hold). cc.nvim
-- cannot approve them, so each hold and drop is shown, and list_instances
-- reports them with the session's live permission mode.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function setup(options)
  _G.child.lua(([==[
    local config = require('cc.config')
    _G.notified = {}
    vim.notify = function(text, level) notified[#notified + 1] = { text = text, level = level } end
    local opts = %s
    opts.statusline = { enabled = false }
    config.setup(opts)
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-holds-' .. vim.uv.hrtime())
    output:ensure_buffer()
    local process = { is_alive = function() return true end, write = function() end, close = function() end }
    _G.inst = {
      session = session, output = output, process = process,
      prompt = { bufnr = vim.api.nvim_create_buf(false, true) },
      provider = { name = 'claude' },
    }
    require('cc')._register_test_instance(output.bufnr, inst)
    _G.router = require('cc.router').new({ session = session, output = output,
      process = process, instance = inst })
    router:dispatch({ type = 'system', subtype = 'init', session_id = 's1', permissionMode = 'auto' })
    _G.hold = function(state, extra)
      local msg = { type = 'system', subtype = 'peer_message_hold', state = state,
        message_uuid = 'm1', lane = 'socket', from = 'uds:/tmp/cc-socks/1.sock',
        from_name = 'worker', uuid = 'u-' .. state, session_id = 's1' }
      for k, v in pairs(extra or {}) do msg[k] = v end
      router:dispatch(msg)
    end
    _G.lines = function()
      return table.concat(vim.api.nvim_buf_get_lines(output.bufnr, 0, -1, false), '\n')
    end
    _G.snapshot = function()
      for _, s in ipairs(require('cc').list_instances()) do
        if s.outputBufnr == output.bufnr then return s end
      end
    end
  ]==]):format(options or '{}'))
end

T['a held message that expires is shown and listed'] = function()
  setup()
  _G.child.lua([[hold('held', { cause = 'mode-mismatch' })]])
  eq(_G.child.lua_get([[lines():find('Held a message from worker (mode-mismatch)', 1, true) ~= nil]]), true)
  eq(_G.child.lua_get('#notified'), 1)
  eq(_G.child.lua_get('notified[1].level'), vim.log.levels.WARN)
  eq(_G.child.lua_get('snapshot().peerHolds[1].state'), 'held')

  _G.child.lua([[hold('dropped', { outcome = 'expired' })]])
  eq(_G.child.lua_get([[lines():find('Message from worker was not delivered (expired)', 1, true) ~= nil]]), true)
  eq(_G.child.lua_get('#notified'), 2)
  local s = _G.child.lua_get('snapshot()')
  eq(s.permissionMode, 'auto')
  eq(#s.peerHolds, 1)
  eq(s.peerHolds[1].messageUuid, 'm1')
  eq(s.peerHolds[1].state, 'dropped')
  eq(s.peerHolds[1].outcome, 'expired')
  eq(s.peerHolds[1].cause, 'mode-mismatch')
  eq(s.peerHolds[1].fromName, 'worker')
end

T['a released message clears its hold quietly'] = function()
  setup()
  _G.child.lua([[hold('held', { cause = 'mode-mismatch' }); hold('released')]])
  eq(_G.child.lua_get('#notified'), 1)
  eq(_G.child.lua_get('#snapshot().peerHolds'), 0)
end

T['disabled notices still record the hold'] = function()
  setup('{ peer_message_hold = { enabled = false } }')
  _G.child.lua([[hold('held', { cause = 'no-mode-asserted' })]])
  eq(_G.child.lua_get('#notified'), 0)
  eq(_G.child.lua_get([[lines():find('Held a message', 1, true) == nil]]), true)
  eq(_G.child.lua_get('snapshot().peerHolds[1].cause'), 'no-mode-asserted')
end

T['permissionMode follows the live mode'] = function()
  setup()
  _G.child.lua([[router:dispatch({ type = 'system', subtype = 'status', permissionMode = 'plan' })]])
  eq(_G.child.lua_get('snapshot().permissionMode'), 'plan')
end

return T
