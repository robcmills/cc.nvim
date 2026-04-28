-- Tests for cc.tshl (treesitter highlight helper) and cc.diff fragment output.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

T['tshl'] = MiniTest.new_set()

T['tshl']['lang_for_path maps common extensions'] = function()
  _G.child.lua([[
    local tshl = require('cc.tshl')
    _G._t_js  = tshl.lang_for_path('foo.js')
    _G._t_ts  = tshl.lang_for_path('foo.ts')
    _G._t_lua = tshl.lang_for_path('foo.lua')
    _G._t_md  = tshl.lang_for_path('foo.md')
    _G._t_nil = tshl.lang_for_path(nil)
    _G._t_empty = tshl.lang_for_path('')
  ]])
  eq(_G.child.lua_get('_G._t_js'),  'javascript')
  eq(_G.child.lua_get('_G._t_ts'),  'typescript')
  eq(_G.child.lua_get('_G._t_lua'), 'lua')
  eq(_G.child.lua_get('_G._t_md'),  'markdown')
  eq(_G.child.lua_get('_G._t_nil'),   vim.NIL)
  eq(_G.child.lua_get('_G._t_empty'), vim.NIL)
end

T['tshl']['has_parser returns false for unknown lang (no crash)'] = function()
  _G.child.lua([[
    local tshl = require('cc.tshl')
    _G._t_unknown = tshl.has_parser('definitely_not_a_lang_xyz')
    _G._t_nil     = tshl.has_parser(nil)
  ]])
  eq(_G.child.lua_get('_G._t_unknown'), false)
  eq(_G.child.lua_get('_G._t_nil'),     false)
end

T['tshl']['apply_fragment is a no-op when parser is missing'] = function()
  _G.child.lua([[
    local tshl = require('cc.tshl')
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'foo bar baz' })
    local row_map = { { row = 0, col_offset = 0 } }
    -- Should return false (no parser) and not raise.
    _G._t_applied = tshl.apply_fragment(bufnr, 'definitely_not_a_lang_xyz', 'x = 1', row_map)
    -- And no extmarks should have been placed.
    local ns = tshl.namespace()
    _G._t_marks = #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  ]])
  eq(_G.child.lua_get('_G._t_applied'), false)
  eq(_G.child.lua_get('_G._t_marks'), 0)
end

T['diff_fragments'] = MiniTest.new_set()

T['diff_fragments']['render_edit_with_fragments yields after/before fragments'] = function()
  _G.child.lua([[
    local diff = require('cc.diff')
    local d = diff.render_edit_with_fragments('a\nb\nc\n', 'a\nB\nc\n')
    _G._t_lines = d.lines
    _G._t_after_text  = d.after  and d.after.text  or nil
    _G._t_before_text = d.before and d.before.text or nil
    _G._t_after_rows  = d.after  and #d.after.row_map  or 0
    _G._t_before_rows = d.before and #d.before.row_map or 0
    _G._t_glyph_col = d.glyph_col
  ]])
  -- Both fragments should contain the changed line and the surrounding context.
  local after  = _G.child.lua_get('_G._t_after_text')
  local before = _G.child.lua_get('_G._t_before_text')
  eq(type(after) == 'string', true)
  eq(type(before) == 'string', true)
  -- The "after" fragment includes the new line "B" and contexts a/c.
  eq(after:find('B', 1, true) ~= nil, true)
  -- The "before" fragment includes the removed line "b".
  eq(before:find('b', 1, true) ~= nil, true)
  -- Glyph column is 8 (INDENT length).
  eq(_G.child.lua_get('_G._t_glyph_col'), 8)
  -- Each fragment has at least one row mapping.
  eq(_G.child.lua_get('_G._t_after_rows')  > 0, true)
  eq(_G.child.lua_get('_G._t_before_rows') > 0, true)
end

T['diff_fragments']['row_map body_idx points at correct lines entry'] = function()
  -- Verify that for each "after" row, the mapped lines[body_idx + 1] entry,
  -- when stripped of the leading INDENT and glyph (col_offset chars), equals
  -- the source row text.
  _G.child.lua([[
    local diff = require('cc.diff')
    local d = diff.render_edit_with_fragments('alpha\nbeta\ngamma\n', 'alpha\nBETA\ngamma\n')
    local source_rows = vim.split(d.after.text, '\n', { plain = true })
    _G._t_ok = true
    _G._t_msg = ''
    for i, m in ipairs(d.after.row_map) do
      local line = d.lines[m.body_idx + 1]
      local code = line:sub(m.col_offset + 1)
      if code ~= source_rows[i] then
        _G._t_ok = false
        _G._t_msg = string.format('row %d: expected %q, got %q (line=%q)',
          i, source_rows[i] or '', code, line)
        break
      end
    end
  ]])
  if not _G.child.lua_get('_G._t_ok') then
    error(_G.child.lua_get('_G._t_msg'))
  end
end

T['diff_fragments']['render_write_with_fragments has an after-only fragment'] = function()
  _G.child.lua([[
    local diff = require('cc.diff')
    local d = diff.render_write_with_fragments('one\ntwo\nthree')
    _G._t_lines = d.lines
    _G._t_after = d.after and d.after.text or nil
    _G._t_before = d.before
    _G._t_col_offset = d.after and d.after.row_map[1].col_offset or nil
  ]])
  eq(_G.child.lua_get('_G._t_after'), 'one\ntwo\nthree')
  eq(_G.child.lua_get('_G._t_before'), vim.NIL)
  -- Write uses "+ " prefix, so col_offset is INDENT (8) + "+ " (2) = 10.
  eq(_G.child.lua_get('_G._t_col_offset'), 10)
end

T['diff_fragments']['render_multiedit_with_fragments shifts body_idx per edit'] = function()
  _G.child.lua([[
    local diff = require('cc.diff')
    local d = diff.render_multiedit_with_fragments({
      { old_string = 'a\n', new_string = 'A\n' },
      { old_string = 'b\n', new_string = 'B\n' },
    })
    _G._t_n_fragments = #d.fragments
    -- For each fragment, body_idx must point at lines that exist.
    local ok = true
    for _, frag in ipairs(d.fragments) do
      for _, snip in pairs({ frag.after, frag.before }) do
        if snip then
          for _, m in ipairs(snip.row_map) do
            if not d.lines[m.body_idx + 1] then ok = false end
          end
        end
      end
    end
    _G._t_ok = ok
  ]])
  eq(_G.child.lua_get('_G._t_n_fragments'), 2)
  eq(_G.child.lua_get('_G._t_ok'), true)
end

T['diff_fragments']['legacy render_edit returns lines only'] = function()
  _G.child.lua([[
    local diff = require('cc.diff')
    local lines = diff.render_edit('a\nb\n', 'a\nB\n')
    _G._t_is_table = type(lines) == 'table'
    _G._t_first_is_string = type(lines[1]) == 'string'
  ]])
  eq(_G.child.lua_get('_G._t_is_table'), true)
  eq(_G.child.lua_get('_G._t_first_is_string'), true)
end

return T
