local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

local function setup_output(child, streaming)
  child.lua(string.format([==[
    require('cc.config').setup({
      streaming = %s,
      markdown_highlight = { agent = true, user = true },
      splash = false,
      statusline = { enabled = false },
    })
    local Output = require('cc.output')
    local Session = require('cc.session')
    local output = Output.new(Session.new(), 'cc-test-stream-batching')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    output:set_window(vim.api.nvim_get_current_win())
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'text' })
    _G._test_output = output
    _G._test_bufnr = bufnr
  ]==], vim.inspect(streaming)))
end

T['delta coalescing'] = MiniTest.new_set()

T['delta coalescing']['combines many deltas into one buffer mutation'] = function()
  setup_output(_G.child, { render_interval_ms = 1000, markdown_hz = -1 })
  _G.child.lua([[
    local output = _G._test_output
    local original = output._append_to_last_line
    _G._append_calls = 0
    output._append_to_last_line = function(self, text, opts)
      _G._append_calls = _G._append_calls + 1
      return original(self, text, opts)
    end
    output:on_delta('text', 'one')
    output:on_delta('text', ' two')
    output:on_delta('text', ' three')
    _G._before_flush = table.concat(
      vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false), '\n')
    output:flush_pending_delta()
    _G._after_flush = table.concat(
      vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false), '\n')
  ]])

  eq(_G.child.lua_get('_G._append_calls'), 1)
  eq(_G.child.lua_get("_G._before_flush:find('one', 1, true)"), vim.NIL)
  eq(_G.child.lua_get("_G._after_flush:find('one two three', 1, true) ~= nil"), true)
end

T['delta coalescing']['configured timer flushes automatically'] = function()
  setup_output(_G.child, { render_interval_ms = 10, markdown_hz = -1 })
  _G.child.lua([[
    _G._test_output:on_delta('text', 'automatic')
    _G._flushed = vim.wait(500, function()
      local text = table.concat(
        vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false), '\n')
      return text:find('automatic', 1, true) ~= nil
    end, 2)
  ]])
  eq(_G.child.lua_get('_G._flushed'), true)
end

T['delta coalescing']['content boundary flushes before completing block'] = function()
  setup_output(_G.child, { render_interval_ms = 1000, markdown_hz = -1 })
  _G.child.lua([[
    _G._test_output:on_delta('text', 'before boundary')
    _G._test_output:on_content_block_stop({ type = 'text' })
    _G._text = table.concat(
      vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false), '\n')
  ]])
  eq(_G.child.lua_get("_G._text:find('before boundary', 1, true) ~= nil"), true)
end

T['tail anchoring'] = MiniTest.new_set()

T['tail anchoring']['runs only for newline or wrap-height transition'] = function()
  setup_output(_G.child, { render_interval_ms = 1000, markdown_hz = -1 })
  _G.child.lua([[
    local output = _G._test_output
    local heights = { 1, 1, 1, 2 }
    output._is_following_tail = function() return true end
    output._tail_text_height = function()
      local value = table.remove(heights, 1)
      return value
    end
    _G._anchor_calls = 0
    output._follow_tail = function()
      _G._anchor_calls = _G._anchor_calls + 1
    end

    output:on_delta('text', 'same row')
    output:flush_pending_delta()
    _G._after_same_row = _G._anchor_calls

    output:on_delta('text', '\nnew row')
    output:flush_pending_delta()
    _G._after_newline = _G._anchor_calls

    output:on_delta('text', ' wraps')
    output:flush_pending_delta()
    _G._after_wrap = _G._anchor_calls
  ]])

  eq(_G.child.lua_get('_G._after_same_row'), 0)
  eq(_G.child.lua_get('_G._after_newline'), 1)
  eq(_G.child.lua_get('_G._after_wrap'), 2)
end

T['markdown throttle'] = MiniTest.new_set()

T['markdown throttle']['negative rate highlights only at block completion'] = function()
  setup_output(_G.child, { render_interval_ms = 1000, markdown_hz = -1 })
  _G.child.lua([[
    local md = require('cc.md_highlight')
    local original = md.update_streaming
    _G._md_updates = 0
    md.update_streaming = function(...)
      _G._md_updates = _G._md_updates + 1
      return original(...)
    end
    _G._test_output:on_delta('text', '**final only**')
    _G._test_output:flush_pending_delta()
    _G._before_stop = _G._md_updates
    _G._test_output:on_content_block_stop({ type = 'text' })
    _G._after_stop = _G._md_updates
    md.update_streaming = original
  ]])

  eq(_G.child.lua_get('_G._before_stop'), 0)
  eq(_G.child.lua_get('_G._after_stop'), 1)
end

T['markdown throttle']['positive rate skips rapid updates and catches up at stop'] = function()
  setup_output(_G.child, { render_interval_ms = 1000, markdown_hz = 0.5 })
  _G.child.lua([[
    local md = require('cc.md_highlight')
    local original = md.update_streaming
    _G._md_updates = 0
    md.update_streaming = function(...)
      _G._md_updates = _G._md_updates + 1
      return original(...)
    end

    _G._test_output:on_delta('text', 'first')
    _G._test_output:flush_pending_delta()
    _G._after_first = _G._md_updates

    _G._test_output:on_delta('text', ' second')
    _G._test_output:flush_pending_delta()
    _G._after_second = _G._md_updates

    _G._test_output:on_content_block_stop({ type = 'text' })
    _G._after_stop = _G._md_updates
    md.update_streaming = original
  ]])

  eq(_G.child.lua_get('_G._after_first'), 1)
  eq(_G.child.lua_get('_G._after_second'), 1)
  eq(_G.child.lua_get('_G._after_stop'), 2)
end

return T
