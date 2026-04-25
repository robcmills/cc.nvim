-- Replay a captured NDJSON dump through the e2e harness and check the
-- viewport invariant continuously during streaming. Used for chasing
-- production bugs that only show up in real claude streams.
--
-- Usage:
--   CC_REPLAY_FIXTURE=/tmp/cc-bug-repro.ndjson \
--   CC_REPLAY_LINES=40 CC_REPLAY_COLUMNS=120 CC_REPLAY_DELAY=5 \
--   bash tests/run.sh --e2e captured_replay
--
-- Defaults:
--   lines=40, columns=120, delay=5ms, config=rob
--
-- The fixture is fed to the real subprocess via fake_claude_slow.sh, so
-- the streaming pipeline (process -> parser -> router -> output) runs end
-- to end, and the live event loop interleaves vim.schedule callbacks the
-- way it does in production.

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')

local FIXTURE = vim.env.CC_REPLAY_FIXTURE
local LINES = tonumber(vim.env.CC_REPLAY_LINES) or 40
local COLS = tonumber(vim.env.CC_REPLAY_COLUMNS) or 120
local DELAY = tonumber(vim.env.CC_REPLAY_DELAY) or 5
local CONFIG = vim.env.CC_REPLAY_CONFIG or 'rob'

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = nil end,
    post_case = function()
      if _G.child then pcall(function() _G.child:close() end); _G.child = nil end
    end,
  },
})

if FIXTURE == nil or FIXTURE == '' then
  T['skipped (CC_REPLAY_FIXTURE unset)'] = function()
    MiniTest.skip('Set CC_REPLAY_FIXTURE to an NDJSON path')
  end
  return T
end
if vim.fn.filereadable(FIXTURE) ~= 1 then
  T['fixture missing'] = function()
    error('CC_REPLAY_FIXTURE not readable: ' .. FIXTURE)
  end
  return T
end

T['captured_replay'] = function()
  -- Stage the fixture under tests/fixtures/ndjson/ since open_with_fixture
  -- expects a name there. Use a deterministic name so re-runs don't pile up.
  local stage_dir = h.ndjson_dir
  local stage_path = stage_dir .. '/__captured_replay.ndjson'
  vim.fn.system({ 'cp', FIXTURE, stage_path })
  if vim.v.shell_error ~= 0 then error('failed to stage fixture') end

  _G.child = h.spawn({ config = CONFIG, lines = LINES, columns = COLS })
  h.open_with_fixture(_G.child, '__captured_replay', { slow_delay_ms = DELAY })

  if not _G.child:wait_for(function(c) return c:find_winid_for_buf('cc-output') ~= nil end, 3000) then
    error('cc-output window never appeared')
  end
  local winid = _G.child:find_winid_for_buf('cc-output')

  -- Long timeout: real captures can be many seconds at delay 5ms
  local samples = h.sample_during_stream(_G.child, winid, {
    interval_ms = 15,
    timeout_ms = 60000,
  })

  io.stdout:write(string.format('\n[replay] %d samples collected over %.1fs\n',
    #samples, samples[#samples].ts_ms / 1000))
  io.stdout:flush()

  -- Severity classes (any one fires a fail; the most severe is reported):
  --   1. botline != last_line              — "snap to top/middle": last line invisible
  --   2. cursor_line != last_line          — follow-tail logic stopped tracking
  --   3. winheight - winline > GAP_TOL     — large gap of empty rows below cursor
  -- GAP_TOL is generous by default (3 rows); tune with CC_REPLAY_GAP_TOL.
  -- Set CC_REPLAY_STRICT=1 to also fail on any gap (winline < winheight).
  local gap_tol = tonumber(vim.env.CC_REPLAY_GAP_TOL) or 3
  local strict = vim.env.CC_REPLAY_STRICT == '1'

  local function classify(s)
    if not s.stable then return nil end
    if s.view.last_line < s.view.winheight then return nil end
    local v = s.view
    if v.botline ~= v.last_line then
      return 'last line not visible (botline=' .. v.botline .. ' last=' .. v.last_line .. ')'
    end
    if v.cursor_line ~= v.last_line then
      return 'cursor not on last line (cursor=' .. v.cursor_line .. ' last=' .. v.last_line .. ')'
    end
    local gap = v.winheight - v.winline
    if strict and gap > 0 then
      return 'gap=' .. gap .. ' (strict)'
    end
    if gap > gap_tol then
      return 'large gap=' .. gap .. ' rows below cursor (tol=' .. gap_tol .. ')'
    end
    return nil
  end

  local first_break, first_reason = nil, nil
  for i, s in ipairs(samples) do
    local r = classify(s)
    if r then first_break, first_reason = i, r; break end
  end

  if first_break then
    local out = { string.format('VIEWPORT BREAK at sample #%d (t=%.1fms): %s',
      first_break, samples[first_break].ts_ms, first_reason) }
    for j = math.max(1, first_break - 5), math.min(#samples, first_break + 3) do
      local sj = samples[j]
      local mark = (j == first_break) and '>>>' or '   '
      table.insert(out, string.format('%s [#%d t=%7.1fms stable=%s] cursor=%d topline=%d botline=%d winline=%d/%d last=%d',
        mark, j, sj.ts_ms, tostring(sj.stable),
        sj.view.cursor_line, sj.view.topline, sj.view.botline,
        sj.view.winline, sj.view.winheight, sj.view.last_line))
    end
    error(table.concat(out, '\n'))
  end
  io.stdout:write(string.format('[replay] no breaks (gap_tol=%d strict=%s) across %d samples\n',
    gap_tol, tostring(strict), #samples))
  io.stdout:flush()
end

return T
