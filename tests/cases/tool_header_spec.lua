-- Tests for tool-call header rendering invariants:
--   * The timer icon and the elapsed-time `(Ns)` suffix must always be
--     present (or absent) together — neither alone is a valid display state.
--   * The fold caret extmark for a tool header must stay on the header line
--     after the header line is rewritten (timer tick / summary update).
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

-- ---------------------------------------------------------------------------
-- Timer icon + elapsed-seconds suffix consistency
-- ---------------------------------------------------------------------------
T['timer'] = MiniTest.new_set()

-- Reproduces: header reads `Subagent: (4s)` after the first timer tick that
-- fires before content_block_stop has a chance to lay down the timer icon.
-- Expectation: if `(Ns)` is present, the timer glyph must be too.
T['timer']['elapsed suffix without timer icon is invalid'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({ tool_icons = { use_nerdfont = true } })
    local session = Session.new()
    local output = Output.new(session, 'cc-test-tool-header-timer-1')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    output:render_user_turn('go')
    output:begin_assistant_turn()
    -- content_block_start lands the bare header. content_block_stop has not
    -- fired yet (input is still streaming via input_json_delta).
    output:on_content_block_start({ type = 'tool_use', id = 't1', name = 'Agent' })
    -- Local timer tick fires at 1s, BEFORE content_block_stop. This is the
    -- window where the bug manifests in real sessions.
    output:update_tool_elapsed('t1', 1.0)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._test_header_line = nil
    for _, l in ipairs(lines) do
      if l:match('Subagent:') then _G._test_header_line = l; break end
    end
  ]])

  local header = _G.child.lua_get('_G._test_header_line')
  eq(type(header), 'string')

  -- Nerdfont timer glyph (U+F051B) or unicode fallback (U+23F1 ⏱).
  local timer_nf = '\xf3\xb0\x94\x9b'
  local timer_fb = '\xe2\x8f\xb1'
  local has_timer_icon = header:find(timer_nf, 1, true) ~= nil
    or header:find(timer_fb, 1, true) ~= nil
  local has_duration = header:match('%(%d+m?s%)$') ~= nil

  -- Invariant: the duration suffix never appears without the timer icon.
  if has_duration then
    eq(has_timer_icon, true)
  end
end

-- The mirror case: after content_block_stop rewrites the header (which strips
-- the prior `(Ns)` suffix), the next tick should reinstate the suffix so the
-- two glyphs stay together. Verifies the steady state, post-stop.
T['timer']['icon and suffix coexist after stop and tick'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({ tool_icons = { use_nerdfont = true } })
    local session = Session.new()
    local output = Output.new(session, 'cc-test-tool-header-timer-2')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    output:render_user_turn('go')
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'tool_use', id = 't1', name = 'Agent' })
    output:on_content_block_stop({
      type = 'tool_use', id = 't1', name = 'Agent',
      input = { description = 'Find timer icon rendering logic', prompt = 'foo' },
    })
    output:update_tool_elapsed('t1', 5.0)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._test_header_line = nil
    for _, l in ipairs(lines) do
      if l:match('Subagent:') then _G._test_header_line = l; break end
    end
  ]])

  local header = _G.child.lua_get('_G._test_header_line')
  eq(type(header), 'string')

  local timer_nf = '\xf3\xb0\x94\x9b'
  local has_timer_icon = header:find(timer_nf, 1, true) ~= nil
  local has_duration = header:match('%(%d+m?s%)$') ~= nil
  eq(has_timer_icon, true)
  eq(has_duration, true)
end

-- ---------------------------------------------------------------------------
-- Fold caret stays on the tool header line across header rewrites
-- ---------------------------------------------------------------------------
T['caret'] = MiniTest.new_set()

-- Reproduces: after the streaming tool block has settled (caret already
-- placed on the header row by a scheduled refresh_carets), a subsequent
-- live timer tick rewrites the header line via nvim_buf_set_lines. Inline
-- virt_text extmarks within the replaced range drift down to the start
-- of the line BELOW. `update_tool_elapsed` does not schedule a refresh,
-- so until the next CursorMoved fires, the caret visually appears on the
-- first content line under the header instead of on the header itself.
T['caret']['caret stays on header row after timer tick'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-caret-timer')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    -- BufWinEnter wires up the CursorMoved/WinScrolled autocmds and lets
    -- foldclosed() return real values during refresh_carets.
    vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })

    output:render_user_turn('go')
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'tool_use', id = 't1', name = 'Agent' })
    output:on_content_block_stop({
      type = 'tool_use', id = 't1', name = 'Agent',
      input = { description = 'Find timer icon rendering logic', prompt = 'foo bar baz' },
    })
    -- Let the scheduled refresh_carets from _append run so the caret extmark
    -- is correctly placed at the header row before we simulate a tick.
    vim.wait(50, function() return false end)

    local Output = require('cc.output')
    local state = Output._buf_state[bufnr]
    _G._test_header_lnum = state.tool_blocks['t1'].header_lnum
    local NS_CARETS = vim.api.nvim_get_namespaces()['cc.carets']

    -- Helper: look up the live extmark row for the header's current caret id.
    local function caret_row()
      local id = state.extmark_ids[_G._test_header_lnum]
      if not id then return nil end
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS_CARETS, id, {})
      return pos and pos[1] or nil
    end

    _G._test_caret_row_before = caret_row()

    -- A live timer tick rewrites the header line in-place via
    -- nvim_buf_set_lines, which drifts inline virt_text extmarks within
    -- the deleted range down to the next line.
    output:update_tool_elapsed('t1', 5.0)
    _G._test_caret_row_after = caret_row()

    -- Also count carets on the header row vs the line below as a
    -- secondary check that no stray extmark slipped through.
    local on_header, on_line_below = 0, 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS_CARETS, 0, -1, {})) do
      if m[2] == _G._test_header_lnum - 1 then on_header = on_header + 1 end
      if m[2] == _G._test_header_lnum then on_line_below = on_line_below + 1 end
    end
    _G._test_on_header = on_header
    _G._test_on_line_below = on_line_below
    _G._test_bufnr = bufnr
  ]])

  local header_lnum = _G.child.lua_get('_G._test_header_lnum')
  local row_before = _G.child.lua_get('_G._test_caret_row_before')
  local row_after = _G.child.lua_get('_G._test_caret_row_after')
  local on_header = _G.child.lua_get('_G._test_on_header')
  local on_line_below = _G.child.lua_get('_G._test_on_line_below')

  -- Sanity: the header had a caret on its row before the tick.
  eq(row_before, header_lnum - 1)
  -- After the in-place header rewrite, the caret must still be on the
  -- header row — not drifted down to the first content line.
  eq(row_after, header_lnum - 1)
  eq(on_header, 1)
  eq(on_line_below, 0)
end

return T
