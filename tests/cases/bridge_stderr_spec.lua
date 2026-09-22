-- Bridge stderr is informational; other stderr remains a warning.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

local function setup_provider(opts)
  _G.child.lua(([==[
    require('cc.config').setup(%s)
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-output')
    _G._test_bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(_G._test_bufnr)
    local provider = require('cc.providers.claude').attach({
      session = session, output = output,
      on_exit = function(code, signal) _G._test_exit = { code, signal } end,
    })
    provider.process.alive = true
    provider.process.stdin = {}
    provider.process.write = function() end
    _G._test_process = provider.process
    _G._test_warnings = {}
    _G._test_capture = function(fn)
      local notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(_G._test_warnings, { msg = msg, level = level })
      end
      local ok, err = pcall(fn)
      local drained = false
      vim.schedule(function() drained = true end)
      vim.wait(1000, function() return drained end)
      vim.notify = notify
      assert(ok, err)
      assert(drained, 'scheduled notices did not drain')
    end
  ]==]):format(vim.inspect(opts or {})))
end

local function feed(data)
  _G.child.lua(('_G._test_capture(function() _G._test_process.on_stderr(%q) end)'):format(data))
end

local function notices()
  local lines = helpers.get_buffer_lines(_G.child)
  return vim.tbl_filter(function(line) return line ~= '' end, lines)
end

local function warnings(lines)
  local expected = {}
  for _, line in ipairs(lines) do
    table.insert(expected, { msg = 'cc.nvim [stderr]: ' .. line, level = vim.log.levels.WARN })
  end
  eq(_G.child.lua_get('_G._test_warnings'), expected)
end

T['bridge line renders one notice without a warning'] = function()
  setup_provider()
  feed('[bridge] foo\n')
  eq(notices(), { '  ── claude: [bridge] foo ──' })
  warnings({})
end

T['mixed chunk routes each line separately'] = function()
  setup_provider()
  feed('[bridge:sdk] a\nplain warning\n')
  eq(notices(), { '  ── claude: [bridge:sdk] a ──' })
  warnings({ 'plain warning' })
end

T['split remote-bridge prefix waits for the rest of the line'] = function()
  setup_provider()
  feed('[remote-bri')
  eq(notices(), {})
  warnings({})
  feed('dge] tail\n')
  eq(notices(), { '  ── claude: [remote-bridge] tail ──' })
  warnings({})
end

T['disabled stderr notices preserve bridge warnings'] = function()
  setup_provider({ remote_control = { stderr_notice = false } })
  feed('[bridge] foo\n')
  eq(notices(), {})
  warnings({ '[bridge] foo' })
end

T['exit flushes a trailing notice and forwards exit arguments'] = function()
  setup_provider({ remote_control = { stderr_notice_format = 'CLI: %s' } })
  feed('[bridge:repl] tail')
  eq(notices(), {})
  _G.child.lua([[
    _G._test_capture(function() _G._test_process.on_exit(2, 15) end)
  ]])
  eq(notices(), { '  ── CLI: [bridge:repl] tail ──' })
  eq(_G.child.lua_get('_G._test_exit'), { 2, 15 })
  warnings({})
end

T['blank lines are dropped and trailing warnings flush once'] = function()
  setup_provider()
  feed('\n\nfirst\n\nlast')
  warnings({ 'first' })
  _G.child.lua([[
    _G._test_capture(function()
      _G._test_process.on_exit(0, 0)
      _G._test_process.on_exit(0, 0)
    end)
  ]])
  eq(notices(), {})
  warnings({ 'first', 'last' })
end

T['embedded bridge prefixes remain warnings'] = function()
  setup_provider()
  feed('warning [bridge] foo\n[remote-bridge:other] bar\n')
  eq(notices(), {})
  warnings({ 'warning [bridge] foo', '[remote-bridge:other] bar' })
end

T['notice rendering is deferred from a fast callback'] = function()
  setup_provider()
  _G.child.lua([[
    local timer = vim.uv.new_timer()
    timer:start(0, 0, function()
      _G._test_fast = vim.in_fast_event()
      _G._test_process.on_stderr('[bridge] scheduled\n')
      timer:stop()
      timer:close()
    end)
    assert(vim.wait(1000, function()
      return table.concat(vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false), '\n')
        :find('scheduled', 1, true) ~= nil
    end))
  ]])
  eq(_G.child.lua_get('_G._test_fast'), true)
  eq(notices(), { '  ── claude: [bridge] scheduled ──' })
  warnings({})
end

return T
