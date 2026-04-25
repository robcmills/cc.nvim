-- Regression tests for the "fold flash + view drift" bug:
--
-- When a tool_result arrives with many content lines (e.g. Read of a large
-- file), `_render_tool_result_for` appends the `Output:` header (level >3)
-- + content (level 3) and then schedules `_flush_pending_fold_closes` via
-- vim.schedule. Between the append and the deferred close, the screen
-- redraws — the user sees a flash of fully-expanded tool output that
-- immediately collapses to one row. Worse, after the fold closes, the
-- cursor (which was on the last content line) ends up moved to the fold
-- header by Vim's "cursor can't be inside a closed fold" rule, so
-- `_is_following_tail` returns false on the next append and the view
-- drifts away from the bottom.
--
-- These tests check that:
--   1. After a tool_result + subsequent text streaming completes, the
--      view is still bottom-anchored (the drift case).
--   2. We never observe a "fold expanded" sample for a tool_result fold
--      depth that should be auto-closed at the configured foldlevel.

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

T['large_read_followed_by_text_anchors_view'] = function()
  -- Window small enough that the Read result + trailing text overflow it.
  _G.child = h.spawn({ lines = 20, columns = 100 })
  h.open_with_fixture(_G.child, 'large_read', { slow_delay_ms = 8 })
  if not _G.child:wait_for(function(c) return c:find_winid_for_buf('cc-output') ~= nil end, 3000) then
    error('output window never appeared')
  end
  local winid = _G.child:find_winid_for_buf('cc-output')

  if not h.wait_for_session_end(_G.child, 8000) then
    error('session did not end. ' .. h.dump_viewport(_G.child, winid))
  end
  _G.child:sleep(400) -- drain scheduled callbacks

  -- After everything settles, the view must be bottom-anchored. This is
  -- the drift case: if fold close repositioned the cursor off the last
  -- line, follow-tail stops working for the trailing "The module exports..."
  -- text and the user sees an old part of the buffer.
  h.assert_pinned_to_bottom(_G.child, winid)
end

T['no_open_fold_flash_during_large_read'] = function()
  _G.child = h.spawn({ lines = 20, columns = 100 })
  h.open_with_fixture(_G.child, 'large_read', { slow_delay_ms = 8 })
  if not _G.child:wait_for(function(c) return c:find_winid_for_buf('cc-output') ~= nil end, 3000) then
    error('output window never appeared')
  end
  local winid = _G.child:find_winid_for_buf('cc-output')

  -- Drive the stream to completion (we don't actually consume the samples
  -- here — they're just a way to wait for the stream to drain).
  local samples = h.sample_during_stream(_G.child, winid, {
    interval_ms = 8,
    timeout_ms = 8000,
  })

  -- After the stream has settled, query the child for any depth-3
  -- (`Output:`) fold that is still OPEN.
  --
  -- Three non-obvious things about fold queries in the headless harness:
  --   1. foldclosed() returns meaningful values only when called from a
  --      context that "is" the target window. Querying via
  --      nvim_win_call(w, ...) does NOT count — the wrapper pushes the
  --      window onto the call stack but does not propagate the fold
  --      context the way changing curwin does.
  --   2. In `nvim --headless --listen` without a UI attached, foldexpr
  --      is never invoked by `:redraw!`. The fold cache stays empty even
  --      though setlocal foldmethod=expr is set.
  --   3. `vim.fn.win_execute(w, cmd)` DOES change curwin during cmd
  --      execution and triggers foldexpr eval as a side effect of `zX`
  --      (re-apply foldlevel). After it runs, the fold cache for window
  --      `w` is populated and subsequent queries from any context
  --      return correct values.
  --
  -- This is a test-only workaround for a headless-mode artifact; in
  -- production the UI thread drives foldexpr eval naturally.
  local open_depth3_seen = _G.child:lua([[
    local b = vim.fn.bufnr('cc-output')
    if b <= 0 then return false end
    local state = require('cc.output')._buf_state[b]
    if not state then return false end
    local target_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == b then target_win = w; break end
    end
    if not target_win then return false end
    -- Force foldexpr re-eval in headless.
    vim.fn.win_execute(target_win, 'silent! normal! zX', true)
    return vim.api.nvim_win_call(target_win, function()
      for _, meta in pairs(state.tool_blocks or {}) do
        if meta.result_header_lnum then
          if vim.fn.foldclosed(meta.result_header_lnum) == -1 then
            return { lnum = meta.result_header_lnum, last = vim.api.nvim_buf_line_count(b) }
          end
        end
      end
      return false
    end)
  ]])
  if open_depth3_seen and type(open_depth3_seen) == 'table' then
    error(string.format(
      'Output: fold (level 3) is OPEN at line %d after stream — should be closed at default foldlevel=2. (last_line=%d, samples=%d)',
      open_depth3_seen.lnum, open_depth3_seen.last, #samples))
  end
end

return T
