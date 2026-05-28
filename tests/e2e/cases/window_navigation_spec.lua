-- E2E tests for window/buffer navigation in/out of cc.nvim sessions.
--
-- Behaviors covered (added in commit ad4da9e and surrounding work):
--   1. Output scroll position survives close-and-reopen of the layout
--   2. last_focus restoration: the cc buffer the user was in when they
--      navigated away is the one focus returns to on reopen
--   3. Multi-instance state isolation: switching between cc instances
--      preserves each instance's focus + scroll independently
--   4. cc-window options (signcolumn, number, etc.) do not leak into
--      non-cc buffers that subsequently occupy the same window
--   5. Interaction with regular file buffers and terminal buffers
--
-- Existing window_options_leak_spec.lua covers a narrow case of (4) for
-- the prompt window; this file extends to the output window and combines
-- (4) with the focus/scroll preservation paths.

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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Open a cc instance (using `many_lines` for ~42 lines of content) and
--- wait for the fake_claude subprocess to finish streaming. After return,
--- both cc buffers exist, the layout is up, and folds have been opened so
--- a small viewport will overflow.
local function open_populated(child, fold_open)
  h.open_with_fixture(child, 'many_lines')
  if not h.wait_for_session_end(child, 8000) then
    error('initial session did not end')
  end
  child:sleep(150)
  if fold_open ~= false then
    child:lua([[ require('cc').set_fold_level(99) ]])
    child:sleep(50)
  end
end

--- After the fake_claude subprocess exits, `inst.process.alive` is false
--- and the BufWinEnter recreate-output path early-returns. In real use the
--- claude CLI stays alive across navigation, so for navigation tests we
--- restore the alive flag on every active cc instance.
local function force_alive(child)
  child:lua([[
    local cc = require('cc')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local inst = cc.find_instance(b)
        if inst and inst.process then
          inst.process.alive = true
        end
      end
    end
  ]])
end

-- Lua snippet (string-pasted into child:lua) that finds a buffer whose
-- absolute name ends in `/<target>` (or is exactly `<target>`). Used in
-- place of vim.fn.bufnr() because bufnr() does prefix/substring matching
-- and would conflate `cc-nvim-prompt` with `cc-nvim-prompt-2`.
local FIND_BUF_BY_NAME = [[
  local function find_buf_by_name(target)
    local suffix = '/' .. target
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local n = vim.api.nvim_buf_get_name(b)
        if n == target or (#n >= #suffix and n:sub(-#suffix) == suffix) then
          return b
        end
      end
    end
    return nil
  end
]]

--- Wait until the buffer `buf_name` contains "Session ended" near its tail.
--- Used for instance 2's stream end (h.wait_for_session_end is hard-coded
--- to cc-nvim-output and would match the wrong buffer in a multi-instance run).
local function wait_for_session_end_in(child, buf_name, timeout_ms)
  return child:wait_for(function(c)
    return c:lua(FIND_BUF_BY_NAME .. string.format([[
      local buf = find_buf_by_name(%q)
      if not buf then return false end
      local last = vim.api.nvim_buf_line_count(buf)
      local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, last - 5), last, false)
      for _, l in ipairs(lines) do
        if l:find('Session ended', 1, true) then return true end
      end
      return false
    ]], buf_name))
  end, timeout_ms or 8000)
end

--- Capture an instance's metadata (bufnrs and current winids) by prompt
--- buffer name. Looks the buffer up by name suffix to avoid matching
--- against the wrong instance when multiple are open.
local function capture_instance(child, prompt_name)
  return child:lua(FIND_BUF_BY_NAME .. string.format([[
    local pbuf = find_buf_by_name(%q)
    if not pbuf then return { error = 'prompt buffer not found: ' .. %q } end
    local inst = require('cc').find_instance(pbuf)
    if not inst then return { error = 'no instance for buf ' .. pbuf } end
    return {
      prompt_bufnr = pbuf,
      output_bufnr = inst.output and inst.output.bufnr or -1,
      prompt_winid = inst.prompt_winid,
      output_winid = inst.output_winid,
      last_focus = inst.last_focus,
      saved_output_view = inst.saved_output_view,
    }
  ]], prompt_name, prompt_name))
end

--- Snapshot of the current window state (which winid/buf is focused, and
--- the view of a named cc-nvim-output buffer if it is currently displayed).
local function current_state(child, output_buf_name)
  return child:lua(FIND_BUF_BY_NAME .. string.format([[
    local cur_win = vim.api.nvim_get_current_win()
    local cur_buf = vim.api.nvim_get_current_buf()
    local cur_buf_name = vim.api.nvim_buf_get_name(cur_buf)
    local out_buf = find_buf_by_name(%q)
    local out_winid = nil
    if out_buf then
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == out_buf then out_winid = w break end
      end
    end
    local out_view = nil
    if out_winid then
      out_view = vim.api.nvim_win_call(out_winid, function() return vim.fn.winsaveview() end)
    end
    return {
      cur_win = cur_win,
      cur_buf = cur_buf,
      cur_buf_name = cur_buf_name,
      output_winid = out_winid,
      output_view = out_view,
    }
  ]], output_buf_name))
end

--- Focus a cc-nvim-output buffer's window and scroll so a specific buffer line
--- sits at the top of the viewport. Returns the resulting winsaveview.
local function focus_output_and_scroll(child, output_buf_name, top_line)
  return child:lua(FIND_BUF_BY_NAME .. string.format([[
    local out_buf = find_buf_by_name(%q)
    if not out_buf then return { error = 'output buf not found' } end
    local out_winid = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == out_buf then out_winid = w break end
    end
    if not out_winid then return { error = 'output not displayed' } end
    vim.api.nvim_set_current_win(out_winid)
    vim.api.nvim_win_set_cursor(out_winid, { %d, 0 })
    vim.cmd('normal! zt')
    vim.cmd('redraw!')
    return vim.api.nvim_win_call(out_winid, function() return vim.fn.winsaveview() end)
  ]], output_buf_name, top_line))
end

--- Switch to a buffer by name in the current window via :buffer N.
local function switch_to_buf_by_name(child, buf_name)
  child:lua(FIND_BUF_BY_NAME .. string.format([[
    local buf = find_buf_by_name(%q)
    if not buf then error('buf not found: ' .. %q) end
    vim.cmd('buffer ' .. buf)
  ]], buf_name, buf_name))
end

-- ---------------------------------------------------------------------------
-- Test 1: prompt focus is the default after navigating away and back.
-- User stays in prompt, runs :edit foo from prompt, comes back via :b cc-nvim-output.
-- (The buflisted output buffer is the canonical re-entry point.)
-- ---------------------------------------------------------------------------

T['prompt_focus_default_after_nav_away_and_back'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })
  open_populated(_G.child)
  force_alive(_G.child)

  local before = capture_instance(_G.child, 'cc-nvim-prompt')
  if before.error then error(before.error) end

  -- :edit a regular file from the prompt window. This replaces cc-nvim-prompt,
  -- triggers prompt's BufWinLeave, which closes the output window as a side
  -- effect (both halves of the cc layout collapse together).
  _G.child:lua([[ pcall(vim.cmd, 'edit plugin/cc.lua') ]])
  _G.child:sleep(200)

  -- Buffer-back to cc-nvim-output. Output's BufWinEnter recreates the prompt
  -- companion below.
  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local after = current_state(_G.child, 'cc-nvim-output')
  local cur_inst = capture_instance(_G.child, 'cc-nvim-prompt')
  if cur_inst.error then error(cur_inst.error) end

  if after.cur_buf ~= before.prompt_bufnr then
    error(string.format('expected current buf to be cc-nvim-prompt (%d), got %d (%q)',
      before.prompt_bufnr, after.cur_buf, after.cur_buf_name))
  end
  if after.cur_win ~= cur_inst.prompt_winid then
    error(string.format('expected current win to be prompt window, got %s',
      tostring(after.cur_win)))
  end
  if not cur_inst.output_winid or not after.output_winid then
    error('expected output companion to be recreated')
  end
end

-- ---------------------------------------------------------------------------
-- Test 2: scroll is preserved when navigating away from PROMPT window.
-- This is the path the ad4da9e fix targets directly.
-- Sequence: focus output, scroll, focus prompt, :edit foo, :b cc-nvim-output.
-- last_focus ends up 'prompt' (last BufLeave was from prompt), so focus
-- returns to prompt — but the saved_output_view IS captured because the
-- output window still holds cc-nvim-output when prompt's BufWinLeave fires.
-- ---------------------------------------------------------------------------

T['scroll_preserved_when_nav_away_from_prompt'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })
  open_populated(_G.child)
  force_alive(_G.child)

  local before_inst = capture_instance(_G.child, 'cc-nvim-prompt')
  if before_inst.error then error(before_inst.error) end

  local view_before = focus_output_and_scroll(_G.child, 'cc-nvim-output', 5)
  if view_before.error then error(view_before.error) end

  -- Hop back to prompt before navigating out.
  _G.child:lua(string.format([[
    vim.api.nvim_set_current_win(%d)
  ]], before_inst.prompt_winid))
  _G.child:sleep(50)

  _G.child:lua([[ pcall(vim.cmd, 'edit plugin/cc.lua') ]])
  _G.child:sleep(200)
  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local after = current_state(_G.child, 'cc-nvim-output')
  if not after.output_winid or not after.output_view then
    error('output window did not come back')
  end
  if after.output_view.topline ~= view_before.topline then
    error(string.format('topline drift: before=%d after=%d (lnum before=%d after=%d)',
      view_before.topline, after.output_view.topline,
      view_before.lnum, after.output_view.lnum))
  end
  if after.output_view.lnum ~= view_before.lnum then
    error(string.format('cursor lnum drift: before=%d after=%d',
      view_before.lnum, after.output_view.lnum))
  end
end

-- ---------------------------------------------------------------------------
-- Test 3: output focus is restored when user navigated away from OUTPUT.
-- Sequence: focus output, scroll, :edit foo from output window, :b cc-nvim-prompt.
-- BufLeave on cc-nvim-output sets last_focus='output', so on reopen the layout
-- recreates output above prompt and moves focus to output.
--
-- Scroll preservation on this path is checked too: it requires the output
-- BufWinLeave handler to snapshot the view (otherwise reopen falls back
-- to the bottom-of-buffer anchor).
-- ---------------------------------------------------------------------------

T['output_focus_and_scroll_restored_when_nav_away_from_output'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })
  open_populated(_G.child)
  force_alive(_G.child)

  local view_before = focus_output_and_scroll(_G.child, 'cc-nvim-output', 6)
  if view_before.error then error(view_before.error) end

  -- :edit a regular file from the OUTPUT window. cc-nvim-output's BufWinLeave
  -- fires here; its handler closes the prompt companion as a side-effect.
  _G.child:lua([[ pcall(vim.cmd, 'edit plugin/cc.lua') ]])
  _G.child:sleep(250)

  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local after = current_state(_G.child, 'cc-nvim-output')
  local cur_inst = capture_instance(_G.child, 'cc-nvim-prompt')
  if cur_inst.error then error(cur_inst.error) end

  if not after.output_winid then
    error('output window not recreated after returning to cc-nvim-prompt')
  end
  if after.cur_win ~= after.output_winid then
    error(string.format(
      'expected focus restored to output (winid=%s), got winid=%s buf=%q',
      tostring(after.output_winid), tostring(after.cur_win), after.cur_buf_name))
  end
  if after.output_view.topline ~= view_before.topline
      or after.output_view.lnum ~= view_before.lnum then
    error(string.format(
      'scroll not preserved across output→file→cc-nvim-prompt path:\n  before: topline=%d lnum=%d\n  after:  topline=%d lnum=%d',
      view_before.topline, view_before.lnum,
      after.output_view.topline, after.output_view.lnum))
  end
end

-- ---------------------------------------------------------------------------
-- Test 4: switching between two cc instances preserves each instance's
-- focus and scroll independently. Instance 1 is left with output focused
-- and scrolled; instance 2 with prompt focused and at default position.
-- ---------------------------------------------------------------------------

T['multi_instance_preserves_per_instance_focus_and_scroll'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })

  -- Instance 1 (cc-nvim-prompt / cc-nvim-output)
  open_populated(_G.child)
  force_alive(_G.child)

  local view1_before = focus_output_and_scroll(_G.child, 'cc-nvim-output', 5)
  if view1_before.error then error(view1_before.error) end

  -- Stay in inst1's OUTPUT window. Opening inst2 from here makes
  -- nvim_set_current_buf fire BufLeave on cc-nvim-output → inst1.last_focus='output'.
  -- (Hopping to prompt first would have set last_focus='prompt' and lost
  -- the per-instance "I was in output" state.)
  _G.child:lua(string.format([[
    vim.env.CC_TEST_FIXTURE = %q
    require('cc').open()
  ]], h.ndjson_dir .. '/many_lines.ndjson'))
  if not wait_for_session_end_in(_G.child, 'cc-nvim-output-2', 8000) then
    error('instance 2 session did not end')
  end
  _G.child:sleep(150)
  _G.child:lua([[ require('cc').set_fold_level(99) ]])
  _G.child:sleep(50)
  force_alive(_G.child)

  -- Stay in instance 2's prompt (default focus). last_focus on inst2 is
  -- nil here; it'll become 'prompt' the moment we run :b cc-nvim-prompt below.

  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local on_inst1 = current_state(_G.child, 'cc-nvim-output')
  if not on_inst1.output_winid then error('inst1 output not recreated') end
  if on_inst1.cur_win ~= on_inst1.output_winid then
    error(string.format(
      'inst1: expected focus on output (winid=%s), got winid=%s buf=%q',
      tostring(on_inst1.output_winid), tostring(on_inst1.cur_win), on_inst1.cur_buf_name))
  end
  if on_inst1.output_view.topline ~= view1_before.topline
    or on_inst1.output_view.lnum ~= view1_before.lnum then
    error(string.format(
      'inst1 scroll drift: before topline=%d lnum=%d, after topline=%d lnum=%d',
      view1_before.topline, view1_before.lnum,
      on_inst1.output_view.topline, on_inst1.output_view.lnum))
  end

  -- Now switch to instance 2. We're in inst1's OUTPUT window. :b cc-nvim-prompt-2
  -- replaces cc-nvim-output with cc-nvim-prompt-2 there: that fires BufLeave on
  -- cc-nvim-output (inst1.last_focus stays 'output') and BufWinEnter on
  -- cc-nvim-prompt-2 which recreates inst2's output companion.
  switch_to_buf_by_name(_G.child, 'cc-nvim-output-2')
  _G.child:sleep(300)

  local on_inst2 = current_state(_G.child, 'cc-nvim-output-2')
  if not on_inst2.output_winid then error('inst2 output not recreated') end
  local inst2_now = capture_instance(_G.child, 'cc-nvim-prompt-2')
  if inst2_now.error then error(inst2_now.error) end
  -- Inst2's last_focus was set to 'prompt' by the BufLeave that fired
  -- when we left inst2's prompt to go to inst1, so focus returns to prompt.
  if on_inst2.cur_win ~= inst2_now.prompt_winid then
    error(string.format(
      'inst2: expected focus on prompt (winid=%s), got winid=%s buf=%q',
      tostring(inst2_now.prompt_winid), tostring(on_inst2.cur_win), on_inst2.cur_buf_name))
  end
end

-- ---------------------------------------------------------------------------
-- Test 5: instances can be interleaved with regular file buffers.
-- Sequence: open inst1, scroll output, open file foo, open inst2, edit
-- another file, switch back to inst1 — assert inst1 state preserved.
-- ---------------------------------------------------------------------------

T['multi_instance_interleaved_with_regular_buffer'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })
  open_populated(_G.child)
  force_alive(_G.child)

  local inst1 = capture_instance(_G.child, 'cc-nvim-prompt')
  if inst1.error then error(inst1.error) end
  local view1_before = focus_output_and_scroll(_G.child, 'cc-nvim-output', 4)
  if view1_before.error then error(view1_before.error) end
  -- Leave focus on output: BufLeave on output later will set last_focus='output'.

  -- Edit foo.lua from output window — exercises the output-side leave path.
  _G.child:lua([[ pcall(vim.cmd, 'edit plugin/cc.lua') ]])
  _G.child:sleep(200)

  -- Open a second cc instance from the foo.lua buffer.
  _G.child:lua(string.format([[
    vim.env.CC_TEST_FIXTURE = %q
    require('cc').open()
  ]], h.ndjson_dir .. '/many_lines.ndjson'))
  if not wait_for_session_end_in(_G.child, 'cc-nvim-output-2', 8000) then
    error('instance 2 session did not end')
  end
  _G.child:sleep(150)
  _G.child:lua([[ require('cc').set_fold_level(99) ]])
  _G.child:sleep(50)
  force_alive(_G.child)

  -- Edit a different regular file from inst2's prompt window.
  _G.child:lua([[ pcall(vim.cmd, 'edit lua/cc/init.lua') ]])
  _G.child:sleep(200)

  -- Return to instance 1.
  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local on_inst1 = current_state(_G.child, 'cc-nvim-output')
  if not on_inst1.output_winid then error('inst1 output not recreated') end
  if on_inst1.cur_win ~= on_inst1.output_winid then
    error(string.format(
      'inst1 after interleave: expected output focus, got winid=%s buf=%q',
      tostring(on_inst1.cur_win), on_inst1.cur_buf_name))
  end
  if on_inst1.output_view.topline ~= view1_before.topline
    or on_inst1.output_view.lnum ~= view1_before.lnum then
    error(string.format(
      'inst1 scroll drift after interleave: before topline=%d lnum=%d, after topline=%d lnum=%d',
      view1_before.topline, view1_before.lnum,
      on_inst1.output_view.topline, on_inst1.output_view.lnum))
  end
end

-- ---------------------------------------------------------------------------
-- Test 6: instances can be interleaved with terminal buffers.
-- Terminal buffers are listed (buftype=terminal, buflisted=true), so they
-- show up in :bnext/:bprev rotation. Switching cc → :terminal → cc must
-- not break the layout or per-instance state.
-- ---------------------------------------------------------------------------

T['multi_instance_interleaved_with_terminal_buffer'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })
  open_populated(_G.child)
  force_alive(_G.child)

  local view1_before = focus_output_and_scroll(_G.child, 'cc-nvim-output', 5)
  if view1_before.error then error(view1_before.error) end

  -- :terminal from inside the OUTPUT window. cc-nvim-output is replaced by the
  -- terminal buffer in place, firing BufLeave on cc-nvim-output (last_focus='output')
  -- and BufWinLeave on cc-nvim-output (snapshots the view; cascades to closing
  -- the prompt companion). `tail -f /dev/null` is portable enough on
  -- macOS/linux to hold the terminal open indefinitely.
  _G.child:lua([[
    vim.cmd('terminal tail -f /dev/null')
    vim.cmd('stopinsert')
  ]])
  _G.child:sleep(200)

  -- Return to cc-nvim-prompt from the terminal buffer.
  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local on_inst1 = current_state(_G.child, 'cc-nvim-output')
  if not on_inst1.output_winid then
    error('inst1 output not recreated after terminal interleave')
  end
  if on_inst1.cur_win ~= on_inst1.output_winid then
    error(string.format(
      'inst1 after terminal interleave: expected output focus, got winid=%s buf=%q',
      tostring(on_inst1.cur_win), on_inst1.cur_buf_name))
  end
  if on_inst1.output_view.topline ~= view1_before.topline
    or on_inst1.output_view.lnum ~= view1_before.lnum then
    error(string.format(
      'inst1 scroll drift after terminal interleave: before topline=%d lnum=%d, after topline=%d lnum=%d',
      view1_before.topline, view1_before.lnum,
      on_inst1.output_view.topline, on_inst1.output_view.lnum))
  end
end

-- ---------------------------------------------------------------------------
-- Test 7: cc-window options (signcolumn, number, etc.) are restored when
-- a non-cc buffer takes over the OUTPUT window via :edit. Complements
-- window_options_leak_spec which exercises the same flow from prompt.
-- ---------------------------------------------------------------------------

T['edit_from_output_window_restores_user_window_opts'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })

  -- User defaults that DIFFER from cc.nvim's overrides.
  _G.child:lua([[
    vim.o.number = true
    vim.o.relativenumber = true
    vim.o.signcolumn = 'yes'
    vim.o.wrap = false
  ]])

  open_populated(_G.child, false)

  -- Move into the output window then :edit a regular file there.
  local inst = capture_instance(_G.child, 'cc-nvim-prompt')
  if inst.error then error(inst.error) end
  _G.child:lua(string.format([[ vim.api.nvim_set_current_win(%d) ]], inst.output_winid))
  _G.child:sleep(50)
  _G.child:lua([[ pcall(vim.cmd, 'edit plugin/cc.lua') ]])
  _G.child:sleep(150)

  local opts = _G.child:lua([[
    local w = vim.api.nvim_get_current_win()
    local b = vim.api.nvim_win_get_buf(w)
    return {
      buf_name = vim.api.nvim_buf_get_name(b),
      number = vim.wo[w].number,
      relativenumber = vim.wo[w].relativenumber,
      signcolumn = vim.wo[w].signcolumn,
      wrap = vim.wo[w].wrap,
    }
  ]])

  if not opts.buf_name:match('plugin/cc%.lua$') then
    error('expected plugin/cc.lua, got: ' .. tostring(opts.buf_name))
  end
  local fail = {}
  if opts.number ~= true then
    table.insert(fail, string.format('number: expected true, got %s', tostring(opts.number)))
  end
  if opts.relativenumber ~= true then
    table.insert(fail, string.format('relativenumber: expected true, got %s', tostring(opts.relativenumber)))
  end
  if opts.signcolumn ~= 'yes' then
    table.insert(fail, string.format('signcolumn: expected "yes", got %q', tostring(opts.signcolumn)))
  end
  if opts.wrap ~= false then
    table.insert(fail, string.format('wrap: expected false, got %s', tostring(opts.wrap)))
  end
  if #fail > 0 then
    error('cc.nvim output-window options leaked into ' .. opts.buf_name .. ':\n  ' ..
      table.concat(fail, '\n  '))
  end
end

-- ---------------------------------------------------------------------------
-- Test 8: tail-follow still works after navigating away from prompt and back.
--
-- Regression: commit 2c98372 (swap output/prompt parent-child) updates
-- `inst.output_winid` in the output BufWinEnter callback but never calls
-- `inst.output:set_window(new_winid)`. After :edit-from-prompt closes the
-- original output window and :b cc-nvim-output reopens the layout in a
-- DIFFERENT window, `inst.output.winid` still points at the original (now
-- closed, invalid) winid. Subsequent calls to `inst.output:follow_tail()`
-- — which is what M.submit() invokes to pin to the bottom before sending
-- a prompt — silently no-op because `_follow_tail` early-returns on
-- invalid winid. User-visible symptom: prompts submitted after window
-- nav don't scroll the output to the tail.
-- ---------------------------------------------------------------------------

T['follow_tail_works_after_nav_away_from_prompt_and_back'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })
  open_populated(_G.child)
  force_alive(_G.child)

  -- Focus prompt before :edit so prompt's BufWinLeave fires (this is the
  -- path that closes the output window and detaches it from inst.output.winid).
  local before = capture_instance(_G.child, 'cc-nvim-prompt')
  if before.error then error(before.error) end
  _G.child:lua(string.format('vim.api.nvim_set_current_win(%d)', before.prompt_winid))
  _G.child:sleep(50)

  _G.child:lua([[ pcall(vim.cmd, 'edit plugin/cc.lua') ]])
  _G.child:sleep(200)
  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local after = capture_instance(_G.child, 'cc-nvim-prompt')
  if after.error then error(after.error) end
  if not after.output_winid then error('output window not recreated') end

  -- Sanity: inst.output.winid (the field _follow_tail consults) should
  -- equal inst.output_winid. With the regression, it lags behind.
  local output_field_winid = _G.child:lua(string.format([[
    local inst = require('cc').find_instance(%d)
    return inst and inst.output and inst.output.winid or nil
  ]], after.prompt_bufnr))
  if output_field_winid ~= after.output_winid then
    error(string.format(
      'inst.output.winid (%s) out of sync with inst.output_winid (%s) after nav-away/back',
      tostring(output_field_winid), tostring(after.output_winid)))
  end

  -- Move cursor to the top of the output buffer so we are clearly NOT
  -- following the tail. follow_tail() must move the cursor back to the
  -- last line and pin the view to the bottom.
  _G.child:lua(string.format([[
    vim.api.nvim_win_set_cursor(%d, { 1, 0 })
  ]], after.output_winid))
  _G.child:sleep(50)

  -- Same call M.submit() makes right before sending a prompt.
  _G.child:lua(string.format([[
    local inst = require('cc').find_instance(%d)
    inst.output:follow_tail()
  ]], after.prompt_bufnr))
  _G.child:sleep(50)

  h.assert_pinned_to_bottom(_G.child, after.output_winid)
end

-- ---------------------------------------------------------------------------
-- Test 9: tail-follow RESUMES after navigating away during an active stream.
--
-- Scenario: the user is following a live agent turn (cursor at the output
-- tail), navigates to another file mid-turn, and returns. While the cc layout
-- is collapsed the turn keeps streaming, growing the buffer well past where it
-- was when the user left.
--
-- Bug: the reopen path restores the snapshot taken on leave verbatim via
-- winrestview. That snapshot's cursor line was the tail *at leave time*, which
-- now sits far above the live tail — so the window reopens frozen above the
-- streaming output and never re-pins (the BufWinEnter `Gzb` only fires when
-- the cursor is already at/after the last line).
--
-- Desired: if the user was following the tail when they left, reopen re-pins
-- to the NEW tail so streaming output keeps scrolling into view.
-- ---------------------------------------------------------------------------

T['tail_follow_resumes_after_nav_away_during_active_stream'] = function()
  _G.child = h.spawn({ lines = 22, columns = 100 })
  -- Slow stream so we can navigate away mid-turn. many_lines overflows the
  -- ~10-line output window many times over.
  h.open_with_fixture(_G.child, 'many_lines', { slow_delay_ms = 30 })

  -- Wait until the output window exists and the buffer has overflowed (so we
  -- are genuinely tailing a long buffer) while the stream is still in flight.
  local winid
  local ok = _G.child:wait_for(function(c)
    winid = c:find_winid_for_buf('cc-nvim-output')
    if not winid then return false end
    local lc = c:lua([[ return vim.api.nvim_buf_line_count(vim.fn.bufnr('cc-nvim-output')) ]])
    return lc and lc >= 12
  end, 4000)
  if not ok then error('output never overflowed mid-stream') end

  -- Focus the output window and pin the cursor to the live tail.
  _G.child:lua(string.format([[
    vim.api.nvim_set_current_win(%d)
    vim.cmd('normal! G')
  ]], winid))
  _G.child:sleep(30)

  local line_at_leave =
    _G.child:lua([[ return vim.api.nvim_buf_line_count(vim.fn.bufnr('cc-nvim-output')) ]])

  -- Navigate away to a regular file from the OUTPUT window. This collapses the
  -- cc layout and snapshots the output view (cursor at the tail).
  _G.child:lua([[ pcall(vim.cmd, 'edit plugin/cc.lua') ]])
  _G.child:sleep(50)

  -- Let the rest of the turn stream in while the layout is collapsed, so the
  -- buffer grows well past where it was when we left.
  if not h.wait_for_session_end(_G.child, 8000) then
    error('session did not end while navigated away')
  end

  -- In real use the claude CLI stays alive across navigation; the fixture
  -- process has exited, so fake liveness to let the reopen path recreate.
  force_alive(_G.child)

  local line_after_grow =
    _G.child:lua([[ return vim.api.nvim_buf_line_count(vim.fn.bufnr('cc-nvim-output')) ]])
  if line_after_grow <= line_at_leave then
    error(string.format('buffer did not grow while away (leave=%d, after=%d) — test is not exercising the bug',
      line_at_leave, line_after_grow))
  end

  -- Return to the cc session.
  switch_to_buf_by_name(_G.child, 'cc-nvim-output')
  _G.child:sleep(300)

  local out_winid = _G.child:find_winid_for_buf('cc-nvim-output')
  if not out_winid then error('output window not recreated on return') end

  -- Tailing should have resumed: the view is pinned to the NEW tail, not
  -- frozen at the stale pre-navigation position.
  h.assert_pinned_to_bottom(_G.child, out_winid)
end

return T
