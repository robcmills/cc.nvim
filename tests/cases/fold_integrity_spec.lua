-- Vim's fold tree must keep matching the fold levels cc records for every
-- line. In-place header rewrites through nvim_buf_set_lines shortened the
-- header's fold by one line per call (see Output:_set_line). With subagent
-- tool timers ticking every second, closed sections spilled their content and
-- the output view jumped around until the tools finished.

local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

--- Replay the subagent fixture and install fold options on its window.
local function setup(child)
  helpers.replay_streaming(child, 'subagent_tasks')
  child.lua([[
    local bufnr = _G._test_bufnr
    vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
    _G._test_output.winid = vim.fn.bufwinid(bufnr)
  ]])
end

--- Lines where Vim's computed fold level differs from the recorded foldexpr.
---@return string[]
local function fold_mismatches(child)
  child.lua([[
    local bufnr = _G._test_bufnr
    local state = require('cc.output')._buf_state[bufnr]
    _G._test_mismatches = vim.api.nvim_win_call(vim.fn.bufwinid(bufnr), function()
      local bad = {}
      for l = 1, vim.api.nvim_buf_line_count(bufnr) do
        local raw = state.fold_levels[l]
        local ours = type(raw) == 'number' and raw or (tonumber(tostring(raw):match('%d+')) or 0)
        local theirs = vim.fn.foldlevel(l)
        if theirs ~= ours then
          bad[#bad + 1] = ('%d: vim=%d ours=%s'):format(l, theirs, tostring(raw))
        end
      end
      return bad
    end)
  ]])
  return child.lua_get('_G._test_mismatches')
end

--- Rewrite the parent Agent header and the nested Bash header several times,
--- the way the elapsed-time timers do once a second.
local function tick_headers(child)
  child.lua([[
    for secs = 5, 8 do
      _G._test_output:update_tool_elapsed('toolu_04test', secs)
      _G._test_output:update_tool_elapsed('toolu_sub01', secs)
    end
  ]])
end

T['fold levels match the recorded foldexpr after replay'] = function()
  setup(_G.child)
  eq(fold_mismatches(_G.child), {})
end

T['repeated header rewrites leave every fold level intact'] = function()
  setup(_G.child)
  tick_headers(_G.child)
  eq(fold_mismatches(_G.child), {})
end

T['rewriting a closed fold header keeps the fold extent'] = function()
  setup(_G.child)
  _G.child.lua([[
    local bufnr = _G._test_bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:match('^  %S+ Subagent:') then _G._parent = i end
    end
    -- foldlevel 1 closes the Agent tool block, so its extent is observable.
    _G._test_output:set_fold_level(1)
    vim.api.nvim_win_call(_G._test_output.winid, function()
      vim.cmd('redraw')
      _G._before = vim.fn.foldclosedend(_G._parent)
    end)
  ]])
  tick_headers(_G.child)
  _G.child.lua([[
    vim.api.nvim_win_call(_G._test_output.winid, function()
      vim.cmd('redraw')
      _G._after = vim.fn.foldclosedend(_G._parent)
    end)
  ]])
  local before = _G.child.lua_get('_G._before')
  eq(before > _G.child.lua_get('_G._parent'), true)
  eq(_G.child.lua_get('_G._after'), before)
end

return T
