-- Streaming-time viewport stress tests.
--
-- The terminal-state tests in viewport_spec catch *post-stream* breaks. This
-- spec catches *intermediate* breaks: it samples the viewport every ~20ms
-- during a slow-streamed fixture and asserts the bottom-pin invariant on
-- every stable sample (one where the buffer's line count was unchanged since
-- the previous sample — mid-append transients are skipped).
--
-- Run with:  bash tests/run.sh --e2e stress

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = nil end,
    post_case = function()
      if _G.child then
        pcall(function() _G.child:close() end)
        _G.child = nil
      end
    end,
  },
})

--- Helper: open a fixture in slow-stream mode and assert the invariant
--- holds at every stable sample once the buffer overflows the window.
local function run_stream_invariant(opts)
  _G.child = h.spawn({ lines = opts.lines, columns = opts.columns or 100 })
  h.open_with_fixture(_G.child, opts.fixture, { slow_delay_ms = opts.delay_ms or 15 })

  -- Wait until the output window exists.
  local found = _G.child:wait_for(function(c)
    return c:find_winid_for_buf('cc-output') ~= nil
  end, 2000)
  if not found then error('output window never appeared') end
  local winid = _G.child:find_winid_for_buf('cc-output')

  local samples = h.sample_during_stream(_G.child, winid, {
    interval_ms = opts.interval_ms or 20,
    timeout_ms = opts.timeout_ms or 12000,
  })

  if #samples < 5 then
    error(string.format('too few samples (%d) — stream may not have run', #samples))
  end
  h.assert_trace_pinned(samples)
end

-- A small window forces the buffer to overflow quickly. multi_block has
-- 16 rendered lines including tools+results — exercises folds during stream.
T['multi_block_small_window'] = function()
  run_stream_invariant({ lines = 20, fixture = 'multi_block', delay_ms = 15 })
end

-- Bigger window: still smaller than the rendered output. tool_progress has
-- streaming progress messages which trigger many appends.
T['tool_progress_small_window'] = function()
  run_stream_invariant({ lines = 18, fixture = 'tool_progress', delay_ms = 15 })
end

-- subagent_tasks fans out and back — lots of fold transitions mid-stream.
T['subagent_tasks_small_window'] = function()
  run_stream_invariant({ lines = 18, fixture = 'subagent_tasks', delay_ms = 15 })
end

-- Bash with a tool result body — exercises the tool result fold insertion path.
T['tool_bash_small_window'] = function()
  run_stream_invariant({ lines = 14, fixture = 'tool_bash', delay_ms = 15 })
end

-- Slower streaming — gives more event-loop ticks between chunks for
-- BufWinEnter / refresh_carets / vim.schedule callbacks to interleave.
T['multi_block_slow_stream'] = function()
  run_stream_invariant({ lines = 20, fixture = 'multi_block', delay_ms = 50, timeout_ms = 20000 })
end

-- Tiny window so even short fixtures overflow.
T['simple_text_tiny_window'] = function()
  run_stream_invariant({ lines = 12, fixture = 'simple_text', delay_ms = 15 })
end

-- A synthesized fixture with many text deltas + multiple tool turns.
T['many_lines_small_window'] = function()
  run_stream_invariant({ lines = 20, fixture = 'many_lines', delay_ms = 15 })
end

-- Force wrapping: narrow column count + long lines.
T['many_lines_narrow_wrap'] = function()
  run_stream_invariant({ lines = 24, columns = 50, fixture = 'many_lines', delay_ms = 15 })
end

-- Parallel-tool fixture: tool results arrive interleaved with subsequent tool starts.
T['parallel_tool_race_small'] = function()
  run_stream_invariant({ lines = 18, fixture = 'parallel_tool_result_race', delay_ms = 20 })
end

return T
