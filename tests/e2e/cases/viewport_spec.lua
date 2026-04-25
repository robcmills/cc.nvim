-- E2E viewport tests for cc.nvim.
--
-- These spawn a real child nvim, attach a programmatic UI, then drive
-- cc.nvim through fake_claude.sh (the same fixture replay shim used by
-- process_integration_spec). Assertions check actual viewport state
-- (topline / line('w$') / cursor row) — the surface where the bug lives.

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      _G.child = nil
    end,
    post_case = function()
      if _G.child then
        pcall(function() _G.child:close() end)
        _G.child = nil
      end
    end,
  },
})

-- Buffer has fewer than winheight lines so we can't assert zb-style topline,
-- but we *can* assert the last line is visible and the cursor sits on it.
T['short_stream_visible_at_bottom'] = function()
  _G.child = h.spawn({ lines = 40, columns = 100 })
  h.open_with_fixture(_G.child, 'simple_text')

  if not h.wait_for_session_end(_G.child, 8000) then
    error('session did not end. ' .. h.dump_viewport(_G.child, _G.child:find_winid_for_buf('cc-output')))
  end
  -- Drain scheduled callbacks (BufWinEnter Gzb, refresh_carets, etc.).
  _G.child:sleep(300)

  local winid = _G.child:find_winid_for_buf('cc-output')
  if not winid then error('no window for cc-output') end
  h.assert_pinned_to_bottom(_G.child, winid)
end

-- Buffer larger than winheight: this is where the bug bites.
T['long_stream_pinned_to_bottom_after_open'] = function()
  -- Force a small window: total 20 lines, prompt 10, output ~7-8 visible.
  _G.child = h.spawn({ lines = 20, columns = 100 })
  h.open_with_fixture(_G.child, 'multi_block')

  if not h.wait_for_session_end(_G.child, 8000) then
    error('session did not end. ' .. h.dump_viewport(_G.child, _G.child:find_winid_for_buf('cc-output')))
  end
  _G.child:sleep(300)

  local winid = _G.child:find_winid_for_buf('cc-output')
  if not winid then error('no window for cc-output') end
  h.assert_pinned_to_bottom(_G.child, winid)
end

-- Mid-stream fold change should not unpin the viewport.
T['fold_collapse_keeps_pin'] = function()
  _G.child = h.spawn({ lines = 20, columns = 100 })
  h.open_with_fixture(_G.child, 'multi_block')

  if not h.wait_for_session_end(_G.child, 8000) then
    error('session did not end. ' .. h.dump_viewport(_G.child, _G.child:find_winid_for_buf('cc-output')))
  end
  _G.child:sleep(300)

  local winid = _G.child:find_winid_for_buf('cc-output')
  if not winid then error('no window for cc-output') end

  -- Move focus to the output window and fully collapse / expand folds.
  _G.child:lua(
    [[
    local winid = ...
    vim.api.nvim_set_current_win(winid)
    vim.cmd('normal! G')
    -- :CcFold 0 (collapse all) then :CcFold 3 (expand all)
    vim.cmd('CcFold 0')
  ]],
    { winid }
  )
  _G.child:sleep(150)
  h.assert_pinned_to_bottom(_G.child, winid)

  _G.child:lua(
    [[
    local winid = ...
    vim.api.nvim_set_current_win(winid)
    vim.cmd('normal! G')
    vim.cmd('CcFold 3')
  ]],
    { winid }
  )
  _G.child:sleep(150)
  h.assert_pinned_to_bottom(_G.child, winid)
end

-- After focusing the output window from the prompt, viewport must be pinned.
-- Mirrors the BufWinEnter `Gzb` path in output.lua:148.
T['refocus_output_window_pins'] = function()
  _G.child = h.spawn({ lines = 20, columns = 100 })
  h.open_with_fixture(_G.child, 'multi_block')

  if not h.wait_for_session_end(_G.child, 8000) then
    error('session did not end. ' .. h.dump_viewport(_G.child, _G.child:find_winid_for_buf('cc-output')))
  end
  _G.child:sleep(300)

  -- Focus prompt, then jump to output (`go` mapping in prompt buffer, or just
  -- via API) — covers the case where the user navigates back to the output.
  local output_winid = _G.child:find_winid_for_buf('cc-output')
  if not output_winid then error('no output window') end
  local prompt_winid = _G.child:find_winid_for_buf('cc-nvim')
  if not prompt_winid then error('no prompt window') end

  _G.child:lua(
    [[
    local prompt = ...
    vim.api.nvim_set_current_win(prompt)
  ]],
    { prompt_winid }
  )
  _G.child:sleep(80)

  _G.child:lua(
    [[
    local out = ...
    vim.api.nvim_set_current_win(out)
  ]],
    { output_winid }
  )
  _G.child:sleep(200)

  h.assert_pinned_to_bottom(_G.child, output_winid)
end

return T
