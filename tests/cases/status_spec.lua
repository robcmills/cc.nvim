-- Tests for cc.status: build_lines content, highlight spans, open/close.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['build_lines'] = MiniTest.new_set()

T['build_lines']['includes session id and core fields'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    local session = Session.new()
    session.id = 'abc-123'
    session.model = 'claude-opus-4-7'
    session.permission_mode = 'plan'
    session.input_tokens = 1500
    session.output_tokens = 750
    session.cost_usd = 0.1234
    local inst = {
      session = session,
      last_session_id = 'abc-123',
      session_name = 'demo',
    }
    _G._lines = require('cc.status').build_lines(inst)
    _G._texts = {}
    for _, l in ipairs(_G._lines) do table.insert(_G._texts, l.text) end
    _G._joined = table.concat(_G._texts, '\n')
  ]])
  local joined = _G.child.lua_get('_G._joined')
  -- sections present
  if not joined:find('Session') then error('missing Session section') end
  if not joined:find('Model') then error('missing Model section') end
  if not joined:find('Usage') then error('missing Usage section') end
  -- session id rendered
  if not joined:find('abc%-123') then error('session id not rendered: ' .. joined) end
  -- session name
  if not joined:find('demo') then error('name not rendered: ' .. joined) end
  -- model + mode
  if not joined:find('claude%-opus%-4%-7') then error('model not rendered') end
  if not joined:find('plan') then error('permission mode not rendered') end
  -- tokens (1.5k / 750)
  if not joined:find('1%.5k') then error('input tokens not rendered') end
  if not joined:find('750') then error('output tokens not rendered') end
  -- cost
  if not joined:find('%$0%.1234') then error('cost not rendered') end
end

T['build_lines']['placeholders for missing values'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    _G._lines = require('cc.status').build_lines({ session = Session.new() })
    local hits = 0
    for _, l in ipairs(_G._lines) do
      if l.text:find('—') then hits = hits + 1 end
    end
    _G._em_count = hits
  ]])
  -- At least id, name, pid, model, permission, context, branch, pr, etc. show "—"
  local n = _G.child.lua_get('_G._em_count')
  if n < 5 then error('expected several "—" placeholders, got ' .. tostring(n)) end
end

T['build_lines']['spans carry highlight groups'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    local session = Session.new()
    session.id = 'xyz'
    local lines = require('cc.status').build_lines({
      session = session, last_session_id = 'xyz',
    })
    _G._groups = {}
    for _, l in ipairs(lines) do
      for _, sp in ipairs(l.spans) do
        _G._groups[sp.hl] = (_G._groups[sp.hl] or 0) + 1
      end
    end
  ]])
  local groups = _G.child.lua_get('_G._groups')
  eq(type(groups.CcStatusSection), 'number')
  eq(type(groups.CcStatusLabel), 'number')
end

T['build_lines']['state reflects process liveness'] = function()
  -- ready state when process alive and no turn in flight
  _G.child.lua([[
    local Session = require('cc.session')
    local session = Session.new()
    local inst = {
      session = session,
      last_session_id = 'x',
      process = { pid = 1, is_alive = function() return true end },
    }
    local lines = require('cc.status').build_lines(inst)
    local hl
    for _, l in ipairs(lines) do
      if l.text:match('state%s+ready') then
        for _, sp in ipairs(l.spans) do
          if sp.hl == 'CcStatusOK' then hl = 'CcStatusOK' end
        end
      end
    end
    _G._hl = hl
  ]])
  eq(_G.child.lua_get('_G._hl'), 'CcStatusOK')

  -- interrupting → CcStatusWarn
  _G.child.lua([[
    local Session = require('cc.session')
    local session = Session.new()
    session.interrupt_pending = true
    local inst = {
      session = session,
      last_session_id = 'x',
      process = { pid = 1, is_alive = function() return true end },
    }
    local lines = require('cc.status').build_lines(inst)
    local hl
    for _, l in ipairs(lines) do
      if l.text:match('state%s+interrupt') then
        for _, sp in ipairs(l.spans) do
          if sp.hl == 'CcStatusWarn' then hl = 'CcStatusWarn' end
        end
      end
    end
    _G._hl = hl
  ]])
  eq(_G.child.lua_get('_G._hl'), 'CcStatusWarn')
end

T['open'] = MiniTest.new_set()

T['open']['warns when no current instance'] = function()
  _G.child.lua([[
    _G._notified = nil
    local orig = vim.notify
    vim.notify = function(msg, lvl) _G._notified = { msg = msg, lvl = lvl } end
    require('cc.status').open()
    vim.notify = orig
  ]])
  local n = _G.child.lua_get('_G._notified')
  eq(type(n), 'table')
  if not (n.msg or ''):find('cc buffer') then
    error('unexpected notify: ' .. tostring(n.msg))
  end
end

return T
