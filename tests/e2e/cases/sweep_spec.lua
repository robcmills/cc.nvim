-- Configuration sweep against a single hostile fixture. The hostile fixture
-- combines:
--   * multi-block agent text (text deltas appended via _append_to_last_line)
--   * tool_use + tool_result blocks (Grep, Read x2, Bash)
--   * tool_progress events (exercise update_tool_elapsed — the in-place
--     header mutation that was unanchored before _with_tail_anchor)
--   * a parallel-tool race (tool_h3 starts before tool_h2's result lands)
--   * long lines that will wrap in narrow windows
--
-- The sweep dimensions vary window height, columns, and inter-line stream
-- delay. Each run is checked with the wide severity predicate (severe break
-- = botline != last_line OR cursor_line != last_line OR gap > tol).

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = nil end,
    post_case = function()
      if _G.child then pcall(function() _G.child:close() end); _G.child = nil end
    end,
  },
})

local function classify(s, gap_tol)
  if not s.stable then return nil end
  if s.view.last_line < s.view.winheight then return nil end
  local v = s.view
  if v.botline ~= v.last_line then
    return 'last line not visible'
  end
  if v.cursor_line ~= v.last_line then
    return 'cursor not on last line'
  end
  if (v.winheight - v.winline) > gap_tol then
    return 'large gap=' .. (v.winheight - v.winline)
  end
  return nil
end

local function run_case(opts)
  _G.child = h.spawn({ config = opts.config or 'minimal', lines = opts.lines, columns = opts.columns })
  h.open_with_fixture(_G.child, 'hostile_stream', { slow_delay_ms = opts.delay_ms or 12 })
  if not _G.child:wait_for(function(c) return c:find_winid_for_buf('cc-output') ~= nil end, 3000) then
    error('output window never appeared')
  end
  local winid = _G.child:find_winid_for_buf('cc-output')
  local samples = h.sample_during_stream(_G.child, winid, {
    interval_ms = 18,
    timeout_ms = 25000,
  })
  if #samples < 10 then error('too few samples (' .. #samples .. ')') end

  local gap_tol = opts.gap_tol or 3
  local first_break, reason = nil, nil
  for i, s in ipairs(samples) do
    local r = classify(s, gap_tol)
    if r then first_break, reason = i, r; break end
  end
  if first_break then
    local out = { string.format('break at sample #%d (t=%.1fms): %s',
      first_break, samples[first_break].ts_ms, reason) }
    for j = math.max(1, first_break - 4), math.min(#samples, first_break + 2) do
      local sj = samples[j]
      local mark = (j == first_break) and '>>>' or '   '
      table.insert(out, string.format('%s [#%d t=%6.1fms stable=%s] cursor=%d topline=%d botline=%d winline=%d/%d last=%d',
        mark, j, sj.ts_ms, tostring(sj.stable),
        sj.view.cursor_line, sj.view.topline, sj.view.botline,
        sj.view.winline, sj.view.winheight, sj.view.last_line))
    end
    error(table.concat(out, '\n'))
  end
end

-- Vary on lines (window height) — narrower forces overflow earlier.
T['lines_15_cols_120'] = function() run_case({ lines = 15, columns = 120 }) end
T['lines_20_cols_120'] = function() run_case({ lines = 20, columns = 120 }) end
T['lines_30_cols_120'] = function() run_case({ lines = 30, columns = 120 }) end
T['lines_40_cols_120'] = function() run_case({ lines = 40, columns = 120 }) end

-- Vary on columns (wrap pressure) — narrower forces more wrapping.
T['lines_25_cols_60'] = function() run_case({ lines = 25, columns = 60 }) end
T['lines_25_cols_80'] = function() run_case({ lines = 25, columns = 80 }) end
T['lines_25_cols_140'] = function() run_case({ lines = 25, columns = 140 }) end

-- Vary on stream timing — slower lets more vim.schedule callbacks interleave.
T['delay_5ms']  = function() run_case({ lines = 22, columns = 100, delay_ms = 5 }) end
T['delay_25ms'] = function() run_case({ lines = 22, columns = 100, delay_ms = 25 }) end
T['delay_60ms'] = function() run_case({ lines = 22, columns = 100, delay_ms = 60, gap_tol = 4 }) end

-- Run with rob_init (the user's actual config — packer plugins, etc.)
T['rob_lines_24_cols_100'] = function() run_case({ config = 'rob', lines = 24, columns = 100 }) end
T['rob_lines_30_cols_80'] = function() run_case({ config = 'rob', lines = 30, columns = 80 }) end
-- Extreme aspect ratio: rob_init reduces the cc-output winheight to ~5 due
-- to sidebar plugins, then 60 cols forces aggressive wrapping. With wrap=on
-- a single buffer line can occupy 2-3 screen rows; in a 5-row window this
-- produces unavoidable layout gaps that aren't anchor drift. Widen the
-- gap tolerance for this single config — the bottom-pin invariants
-- (botline=last_line, cursor=last_line) still hold.
T['rob_lines_18_cols_60'] = function() run_case({ config = 'rob', lines = 18, columns = 60, gap_tol = 4 }) end

return T
