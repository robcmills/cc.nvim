-- Running-tool timers in the quiet state. Every running tool used to have
-- its own 1 s timer that rewrote its header even inside a closed fold, ran
-- Gzb, and rebuilt every caret. Now one clock ticks all tools, the elapsed
-- value lives in tool metadata, and a header is rewritten only when its
-- text changes and a window shows it. Hidden headers are written once they
-- come into view; folded summaries read the value from metadata.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

-- A turn whose Work group holds a finished `ls` and a running `yarn lint`
-- (t2). The clock interval is long so only explicit ticks run.
local PRELUDE = [[
  local Output = require('cc.output')
  local timers = require('cc.output.timers')
  require('cc.config').setup({ tool_icons = { use_nerdfont = false },
    tool_timer_interval_ms = 600000 })
  local output = Output.new(require('cc.session').new(), 'cc-test-tool-timers')
  local bufnr = output:ensure_buffer()
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
  output:set_window(vim.api.nvim_get_current_win())
  vim.wo.wrap = false
  local function tool(id, command)
    output:begin_assistant_turn()
    local block = { type = 'tool_use', id = id, name = 'Bash', input = { command = command } }
    output:on_content_block_start(block)
    output:start_tool_timer(id)
    output:on_content_block_stop(block)
  end
  output:render_user_turn('go')
  tool('t1', 'ls')
  output:render_tool_result('t1', 'a', false)
  tool('t2', 'yarn lint')
  local state = Output._buf_state[bufnr]
  local function header() return vim.fn.getline(state.tool_blocks.t2.header_lnum) end
  _G._t2_header = header
  local function work() for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:match('Work:') then return i end
  end end
  -- Count calls to Output methods while running fn.
  local function count(names, fn)
    local counts, saved = {}, {}
    for _, name in ipairs(names) do
      counts[name] = 0
      saved[name] = output[name]
      output[name] = function(...) counts[name] = counts[name] + 1; return saved[name](...) end
    end
    fn()
    for _, name in ipairs(names) do output[name] = nil end
    return counts
  end
]]

local function run(script)
  _G.child.lua(PRELUDE .. script)
end

T['all running tools share one clock'] = function()
  run([[
    output:start_tool_timer('t3')
    _G._clock = output._tool_clock ~= nil
    output:stop_tool_timer('t2')
    _G._after_one = output._tool_clock ~= nil
    output:stop_tool_timer('t3')
    _G._after_all = output._tool_clock == nil
  ]])
  eq(_G.child.lua_get('_G._clock'), true)
  eq(_G.child.lua_get('_G._after_one'), true)
  eq(_G.child.lua_get('_G._after_all'), true)
end

T['a visible header is rewritten, an unchanged one is not'] = function()
  run([[
    vim.wo.foldlevel = 4
    vim.cmd('redraw')
    _G._counts = count({ '_set_line' }, function()
      output:update_tool_elapsed('t2', 5)
      output:update_tool_elapsed('t2', 5.4)
    end)
    _G._header = header()
  ]])
  eq(_G.child.lua_get('_G._counts'), { _set_line = 1 })
  eq(_G.child.lua_get('_G._header'), '    ❯ Bash: yarn lint ⏱ 5s')
end

T['a header in a closed fold is not rewritten, but its summary ticks'] = function()
  run([[
    vim.wo.foldlevel = 1
    vim.cmd('redraw')
    _G._before = header()
    _G._counts = count({ '_set_line', '_follow_tail' }, function()
      output:update_tool_elapsed('t2', 7)
    end)
    _G._after = header()
    _G._stale = output._stale_headers.t2 == true
    _G._summary = vim.fn.foldtextresult(work())
  ]])
  eq(_G.child.lua_get('_G._counts'), { _set_line = 0, _follow_tail = 0 })
  eq(_G.child.lua_get('_G._after'), _G.child.lua_get('_G._before'))
  eq(_G.child.lua_get('_G._stale'), true)
  eq(_G.child.lua_get('_G._summary'), '  ▸ ⚒ Work: 2 tool calls · ❯ Bash: yarn lint ⏱ 7s')
end

T['a tick repaints the closed fold line that shows a hidden header'] = function()
  run([[
    vim.wo.foldlevel = 1
    vim.cmd('redraw')
    output._tool_timers.t2.start_ms = vim.uv.now() - 700000
    local orig = vim.api.nvim__redraw
    _G._redraws = {}
    vim.api.nvim__redraw = function(opts)
      if opts.range then table.insert(_G._redraws, opts.range) end
      return orig(opts)
    end
    timers.tick(output)
    -- Same second again: the foldtext is unchanged, so nothing repaints.
    timers.tick(output)
    vim.api.nvim__redraw = orig
    _G._work = work()
  ]])
  local work = _G.child.lua_get('_G._work')
  eq(_G.child.lua_get('_G._redraws'), { { work - 1, work } })
end

T['opening the fold writes the stale header'] = function()
  run([[
    vim.wo.foldlevel = 1
    vim.cmd('redraw')
    output:update_tool_elapsed('t2', 9)
    vim.wo.foldlevel = 4
    vim.cmd('redraw')
  ]])
  -- The sync is scheduled from the redraw; this RPC call runs after it.
  eq(_G.child.lua_get('_G._t2_header()'), '    ❯ Bash: yarn lint ⏱ 9s')
end

T['a header scrolled off screen is written when it scrolls back'] = function()
  run([[
    vim.wo.foldlevel = 4
    for i = 1, 100 do output:render_notice('filler ' .. i) end
    vim.cmd('normal! G')
    vim.cmd('redraw')
    _G._before = header()
    output:update_tool_elapsed('t2', 11)
    _G._offscreen = header()
    vim.cmd('normal! gg')
    vim.cmd('redraw')
  ]])
  eq(_G.child.lua_get('_G._offscreen'), _G.child.lua_get('_G._before'))
  eq(_G.child.lua_get('_G._t2_header()'), '    ❯ Bash: yarn lint ⏱ 11s')
end

T['stopping writes the final value into a hidden header'] = function()
  run([[
    vim.wo.foldlevel = 1
    vim.cmd('redraw')
    output._tool_timers.t2.start_ms = vim.uv.now() - 13000
    output:stop_tool_timer('t2')
    _G._header = header()
  ]])
  eq(_G.child.lua_get('_G._header'):match('⏱ 1[34]s$') ~= nil, true)
end

T['a rewrite that keeps the header height leaves the view alone'] = function()
  run([[
    vim.wo.foldlevel = 4
    vim.cmd('normal! G')
    vim.cmd('redraw')
    _G._same = count({ '_follow_tail' }, function()
      output:update_tool_elapsed('t2', 5)
    end)
    -- A header exactly as wide as the window (counting the inline "▾ "
    -- caret) wraps once 9s becomes 10s.
    vim.wo.wrap = true
    local lnum = state.tool_blocks.t2.header_lnum
    local width = vim.api.nvim_win_get_width(0) - vim.fn.strdisplaywidth('▾ ')
    local base = '    ❯ Bash: '
    base = base .. string.rep('x', width - vim.fn.strdisplaywidth(base .. ' ⏱ 9s'))
    output:_set_line(lnum, base)
    output:update_tool_elapsed('t2', 9)
    vim.cmd('normal! G')
    vim.cmd('redraw')
    _G._taller = count({ '_follow_tail' }, function()
      output:update_tool_elapsed('t2', 10)
    end)
  ]])
  eq(_G.child.lua_get('_G._same'), { _follow_tail = 0 })
  eq(_G.child.lua_get('_G._taller'), { _follow_tail = 1 })
end

T['refresh_carets with nothing changed writes no extmarks'] = function()
  run([[
    vim.wo.foldlevel = 4
    vim.cmd('redraw')
    Output.refresh_carets(bufnr)
    local orig_set, orig_del = vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_del_extmark
    _G._writes = 0
    vim.api.nvim_buf_set_extmark = function(...) _G._writes = _G._writes + 1; return orig_set(...) end
    vim.api.nvim_buf_del_extmark = function(...) _G._writes = _G._writes + 1; return orig_del(...) end
    Output.refresh_carets(bufnr)
    _G._unchanged = _G._writes
    vim.wo.foldlevel = 1
    Output.refresh_carets(bufnr)
    vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_del_extmark = orig_set, orig_del
    _G._changed = _G._writes
  ]])
  eq(_G.child.lua_get('_G._unchanged'), 0)
  eq(_G.child.lua_get('_G._changed') > 0, true)
end

T['scheduled caret refreshes coalesce'] = function()
  run([[
    local ft = require('cc.output.foldtext')
    local orig = ft.refresh_carets
    _G._calls = 0
    ft.refresh_carets = function(...) _G._calls = _G._calls + 1; return orig(...) end
    for _ = 1, 5 do Output.schedule_refresh_carets(bufnr) end
    vim.schedule(function() ft.refresh_carets = orig end)
  ]])
  eq(_G.child.lua_get('_G._calls'), 1)
end

return T
