-- Per-event rendering costs that grew with session length or did window
-- work for nothing: subagent tool inserts, deferred fold closes, foldtext
-- lookups, and the streaming tail append.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

-- A live turn with a parent Agent block (p1) whose input has rendered.
local PRELUDE = [[
  local Output = require('cc.output')
  require('cc.config').setup({ tool_timer_interval_ms = 600000 })
  local output = Output.new(require('cc.session').new(), 'cc-test-render-cost')
  local bufnr = output:ensure_buffer()
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
  output:set_window(vim.api.nvim_get_current_win())
  output:render_user_turn('go')
  output:begin_assistant_turn()
  local agent = { type = 'tool_use', id = 'p1', name = 'Agent',
    input = { description = 'Look around', prompt = 'read stuff' } }
  output:on_content_block_start(agent)
  output:on_content_block_stop(agent)
  local state = Output._buf_state[bufnr]
  local function lines() return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end
]]

local function run(script) _G.child.lua(PRELUDE .. script) end

T["a subagent tool's header and input go in with one insert"] = function()
  run([[
    output:subagent_tool_use('p1', { id = 's0', name = 'Read', input = { file_path = 'a.lua' } })
    -- Something below the Agent block, so the next insert lands mid-buffer.
    output:render_notice('later')
    local shifts = 0
    local orig = output._shift_line_refs
    output._shift_line_refs = function(...) shifts = shifts + 1; return orig(...) end
    output:subagent_tool_use('p1', { id = 's1', name = 'Edit',
      input = { file_path = 'a.lua', old_string = 'x = 1', new_string = 'x = 2' } })
    output._shift_line_refs = nil
    _G._shifts = shifts
    local meta = state.tool_blocks.s1
    _G._header = lines()[meta.header_lnum]
    _G._input = vim.list_slice(lines(), meta.header_lnum + 1, meta.input_end_lnum)
  ]])
  eq(_G.child.lua_get('_G._shifts'), 1)
  eq(_G.child.lua_get('_G._header'):match('Edit: a.lua') ~= nil, true)
  local input = _G.child.lua_get('_G._input')
  eq(vim.trim(input[#input - 1]), '-x = 1')
  eq(vim.trim(input[#input]), '+x = 2')
end

T['deferred fold closes skip the view save when nothing needs zc'] = function()
  run([[
    vim.wo.foldlevel = 0
    vim.cmd('redraw')
    local saves = 0
    local orig = vim.fn.winsaveview
    vim.fn.winsaveview = function(...) saves = saves + 1; return orig(...) end
    -- Ready to close (its input follows), but already inside the closed
    -- turn fold.
    local lnum = state.tool_blocks.p1.header_lnum
    local depth = tonumber(tostring(state.fold_levels[lnum]):match('%d+'))
    state.pending_fold_closes = { { lnum = lnum, depth = depth } }
    Output._flush_pending_fold_closes(bufnr)
    vim.fn.winsaveview = orig
    _G._saves = saves
  ]])
  eq(_G.child.lua_get('_G._saves'), 0)
end

T['foldtext lookups are indexed once per buffer change'] = function()
  run([[
    local ft = require('cc.output.foldtext')
    local a = ft._header_index(bufnr, state)
    local b = ft._header_index(bufnr, state)
    output:render_notice('changed')
    local c = ft._header_index(bufnr, state)
    _G._same = a == b
    _G._rebuilt = c ~= b
    _G._found = c.tools[state.tool_blocks.p1.header_lnum] == state.tool_blocks.p1
  ]])
  eq(_G.child.lua_get('_G._same'), true)
  eq(_G.child.lua_get('_G._rebuilt'), true)
  eq(_G.child.lua_get('_G._found'), true)
end

T['streaming text extends the markdown region it lands in'] = function()
  run([[
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'text' })
    output:on_delta('text', 'Some `code` here')
    output:flush_pending_delta()
    output:_maybe_update_streaming_markdown(true)
    local parser = vim.treesitter.highlighter.active[bufnr].tree
    local function last_region_end()
      local regions = parser:included_regions()
      local r = regions[#regions][1]
      return { r[4], r[5] }
    end
    output:_append_to_last_line(' and more')
    local n = vim.api.nvim_buf_line_count(bufnr)
    _G._end = last_region_end()
    _G._eol = { n - 1, #lines()[n] }
  ]])
  eq(_G.child.lua_get('_G._end'), _G.child.lua_get('_G._eol'))
end

return T
