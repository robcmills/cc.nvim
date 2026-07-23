-- Tests for cc.tshl (treesitter highlight helper) and cc.diff fragment output.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
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

T['diff_fragments']['Codex multi-file diffs yield per-language fragments'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local body = output._default_tool_body('FileChange', {
      changes = {
        {
          path = '/tmp/README.md',
          kind = { type = 'update' },
          diff = '@@ -1,2 +1,2 @@\n # Title\n-old text\n+new text',
        },
        {
          path = '/tmp/provider.lua',
          kind = { type = 'update' },
          diff = '@@ -1 +1 @@\n-local enabled = false\n+local enabled = true',
        },
      },
    })
    _G._t_lines = body.lines
    _G._t_n_snips = #body.snippets
    _G._t_langs = {}
    _G._t_maps_ok = true
    for _, snip in ipairs(body.snippets) do
      table.insert(_G._t_langs, snip.lang)
      local source_rows = vim.split(snip.fragment.text, '\n', { plain = true })
      for i, m in ipairs(snip.fragment.row_map) do
        local line = body.lines[m.body_idx + 1]
        if not line or line:sub(m.col_offset + 1) ~= source_rows[i] then
          _G._t_maps_ok = false
        end
      end
    end
  ]])

  eq(_G.child.lua_get('_G._t_lines'), {
    '/tmp/README.md (update)',
    '  @@ -1,2 +1,2 @@',
    '   # Title',
    '  -old text',
    '  +new text',
    '/tmp/provider.lua (update)',
    '  @@ -1 +1 @@',
    '  -local enabled = false',
    '  +local enabled = true',
  })
  eq(_G.child.lua_get('_G._t_n_snips'), 4)
  eq(_G.child.lua_get('_G._t_langs'),
    { 'markdown', 'markdown', 'lua', 'lua' })
  eq(_G.child.lua_get('_G._t_maps_ok'), true)
end

T['yaml_scalar'] = MiniTest.new_set()

T['yaml_scalar']['extracts block scalar (multi-line value)'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local lines = {
      'action: javascript_exec',
      'tabId: 2101896151',
      'text: |',
      '  fetch(url).then(r => r.json()).then(spec => {',
      '    return spec;',
      '  })',
    }
    local frag = output._extract_yaml_scalar(lines, 'text')
    _G._t_text = frag and frag.text or nil
    _G._t_n_rows = frag and #frag.row_map or 0
    _G._t_first_body_idx = frag and frag.row_map[1].body_idx or nil
    _G._t_first_col_offset = frag and frag.row_map[1].col_offset or nil
  ]])
  eq(_G.child.lua_get('_G._t_text'),
    'fetch(url).then(r => r.json()).then(spec => {\n  return spec;\n})')
  eq(_G.child.lua_get('_G._t_n_rows'), 3)
  eq(_G.child.lua_get('_G._t_first_body_idx'), 3)
  eq(_G.child.lua_get('_G._t_first_col_offset'), 2)
end

T['yaml_scalar']['extracts inline scalar (single-line value)'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local lines = {
      'action: javascript_exec',
      'tabId: 2101896151',
      "text: fetch('/foo').then(r => r.status)",
    }
    local frag = output._extract_yaml_scalar(lines, 'text')
    _G._t_text = frag and frag.text or nil
    _G._t_n_rows = frag and #frag.row_map or 0
    _G._t_body_idx = frag and frag.row_map[1].body_idx or nil
    _G._t_col_offset = frag and frag.row_map[1].col_offset or nil
  ]])
  eq(_G.child.lua_get('_G._t_text'), "fetch('/foo').then(r => r.status)")
  eq(_G.child.lua_get('_G._t_n_rows'), 1)
  eq(_G.child.lua_get('_G._t_body_idx'), 2)
  -- col_offset = #'text: ' = 6
  eq(_G.child.lua_get('_G._t_col_offset'), 6)
end

T['yaml_scalar']['returns nil when key absent'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local frag = output._extract_yaml_scalar({ 'foo: bar', 'baz: qux' }, 'text')
    _G._t_frag = frag
  ]])
  eq(_G.child.lua_get('_G._t_frag'), vim.NIL)
end

T['yaml_body'] = MiniTest.new_set()

T['yaml_body']['full_body_fragment maps each line at col_offset 0'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local lines = { 'actions:', '  -', '    name: computer' }
    local frag = output._full_body_fragment(lines)
    _G._t_text = frag and frag.text or nil
    _G._t_n_rows = frag and #frag.row_map or 0
    _G._t_first_idx = frag and frag.row_map[1].body_idx or nil
    _G._t_first_off = frag and frag.row_map[1].col_offset or nil
    _G._t_last_idx = frag and frag.row_map[3].body_idx or nil
  ]])
  eq(_G.child.lua_get('_G._t_text'), 'actions:\n  -\n    name: computer')
  eq(_G.child.lua_get('_G._t_n_rows'), 3)
  eq(_G.child.lua_get('_G._t_first_idx'), 0)
  eq(_G.child.lua_get('_G._t_first_off'), 0)
  eq(_G.child.lua_get('_G._t_last_idx'), 2)
end

T['yaml_body']['full_body_fragment returns nil for empty body'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    _G._t_empty = output._full_body_fragment({})
    _G._t_nil = output._full_body_fragment(nil)
  ]])
  eq(_G.child.lua_get('_G._t_empty'), vim.NIL)
  eq(_G.child.lua_get('_G._t_nil'), vim.NIL)
end

T['yaml_body']['default_tool_body emits yaml snippet for generic tools'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local body = output._default_tool_body('mcp__claude-in-chrome__browser_batch', {
      actions = {
        { name = 'computer', input = { action = 'left_click', tabId = 42 } },
      },
    })
    _G._t_is_table = type(body) == 'table' and body.lines ~= nil
    _G._t_n_snips = body.snippets and #body.snippets or 0
    _G._t_first_lang = body.snippets and body.snippets[1].lang or nil
    -- The yaml fragment text should equal the joined body lines.
    _G._t_yaml_matches = body.snippets[1].fragment.text == table.concat(body.lines, '\n')
  ]])
  eq(_G.child.lua_get('_G._t_is_table'), true)
  eq(_G.child.lua_get('_G._t_n_snips') >= 1, true)
  eq(_G.child.lua_get('_G._t_first_lang'), 'yaml')
  eq(_G.child.lua_get('_G._t_yaml_matches'), true)
end

T['yaml_body']['javascript_tool keeps yaml + js snippet ordering'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local body = output._default_tool_body('mcp__claude-in-chrome__javascript_tool', {
      tabId = 42,
      text = "fetch('/foo').then(r => r.status)",
    })
    _G._t_n = body.snippets and #body.snippets or 0
    _G._t_first = body.snippets and body.snippets[1].lang or nil
    _G._t_second = body.snippets and body.snippets[2] and body.snippets[2].lang or nil
  ]])
  -- yaml comes first (covers all body), javascript overlays the `text:` value.
  eq(_G.child.lua_get('_G._t_n'), 2)
  eq(_G.child.lua_get('_G._t_first'), 'yaml')
  eq(_G.child.lua_get('_G._t_second'), 'javascript')
end

T['browser_batch'] = MiniTest.new_set()

T['browser_batch']['extracts inline js text fragment for javascript_exec action'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local body = output._default_tool_body('mcp__claude-in-chrome__browser_batch', {
      actions = {
        {
          name = 'javascript_tool',
          input = {
            action = 'javascript_exec',
            tabId = 42,
            text = "JSON.stringify({ x: 1 })",
          },
        },
      },
    })
    _G._t_n_snips = body.snippets and #body.snippets or 0
    _G._t_first_lang = body.snippets and body.snippets[1].lang or nil
    _G._t_last_lang = body.snippets and body.snippets[#body.snippets].lang or nil
    -- The JS fragment text should be the inline value of the action's `text:` field.
    local js = body.snippets[#body.snippets]
    _G._t_js_text = js.fragment.text
    _G._t_js_n_rows = #js.fragment.row_map
    -- Verify the row_map lands on the correct body line, and the col_offset
    -- skips the `      text: ` prefix (12 chars).
    local m = js.fragment.row_map[1]
    _G._t_js_line = body.lines[m.body_idx + 1]
    _G._t_js_col_offset = m.col_offset
  ]])
  eq(_G.child.lua_get('_G._t_n_snips'), 2)
  eq(_G.child.lua_get('_G._t_first_lang'), 'yaml')
  eq(_G.child.lua_get('_G._t_last_lang'), 'javascript')
  eq(_G.child.lua_get('_G._t_js_text'), 'JSON.stringify({ x: 1 })')
  eq(_G.child.lua_get('_G._t_js_n_rows'), 1)
  eq(_G.child.lua_get('_G._t_js_line'), '      text: JSON.stringify({ x: 1 })')
  eq(_G.child.lua_get('_G._t_js_col_offset'), 12)
end

T['browser_batch']['extracts block-scalar js text fragment'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local body = output._default_tool_body('mcp__claude-in-chrome__browser_batch', {
      actions = {
        {
          name = 'javascript_tool',
          input = {
            action = 'javascript_exec',
            tabId = 42,
            text = "const x = 1;\nconsole.log(x);",
          },
        },
      },
    })
    local js = body.snippets[#body.snippets]
    _G._t_lang = js.lang
    _G._t_text = js.fragment.text
    _G._t_n_rows = #js.fragment.row_map
    _G._t_first_off = js.fragment.row_map[1].col_offset
  ]])
  eq(_G.child.lua_get('_G._t_lang'), 'javascript')
  eq(_G.child.lua_get('_G._t_text'), 'const x = 1;\nconsole.log(x);')
  eq(_G.child.lua_get('_G._t_n_rows'), 2)
  -- text content under `      text: |` is indented 8 spaces.
  eq(_G.child.lua_get('_G._t_first_off'), 8)
end

T['browser_batch']['skips non-javascript_exec actions'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local body = output._default_tool_body('mcp__claude-in-chrome__browser_batch', {
      actions = {
        {
          name = 'read_console_messages',
          input = { tabId = 42, pattern = 'foo' },
        },
        {
          name = 'javascript_tool',
          input = { action = 'javascript_exec', tabId = 42, text = 'x()' },
        },
        {
          name = 'javascript_tool',
          -- Different action subtype: should NOT be highlighted as JS.
          input = { action = 'find', tabId = 42, text = 'submit' },
        },
      },
    })
    -- Exactly one JS snippet, plus the YAML one.
    local js_count = 0
    for _, s in ipairs(body.snippets) do
      if s.lang == 'javascript' then js_count = js_count + 1 end
    end
    _G._t_js_count = js_count
    -- Verify the JS fragment is for the second action's text.
    for _, s in ipairs(body.snippets) do
      if s.lang == 'javascript' then _G._t_js_text = s.fragment.text break end
    end
  ]])
  eq(_G.child.lua_get('_G._t_js_count'), 1)
  eq(_G.child.lua_get('_G._t_js_text'), 'x()')
end

T['browser_batch']['handles multiple javascript_exec actions independently'] = function()
  _G.child.lua([[
    local output = require('cc.output')
    local body = output._default_tool_body('mcp__claude-in-chrome__browser_batch', {
      actions = {
        {
          name = 'javascript_tool',
          input = { action = 'javascript_exec', tabId = 1, text = 'first()' },
        },
        {
          name = 'javascript_tool',
          input = { action = 'javascript_exec', tabId = 2, text = 'second()' },
        },
      },
    })
    local js_texts = {}
    for _, s in ipairs(body.snippets) do
      if s.lang == 'javascript' then table.insert(js_texts, s.fragment.text) end
    end
    _G._t_js_texts = js_texts
    -- Each fragment must point at a body line that contains its text.
    local ok = true
    for _, s in ipairs(body.snippets) do
      if s.lang == 'javascript' then
        local m = s.fragment.row_map[1]
        local line = body.lines[m.body_idx + 1]
        if not line or not line:find(s.fragment.text, 1, true) then
          ok = false
          break
        end
      end
    end
    _G._t_rows_ok = ok
  ]])
  eq(_G.child.lua_get('_G._t_js_texts'), { 'first()', 'second()' })
  eq(_G.child.lua_get('_G._t_rows_ok'), true)
end

return T
