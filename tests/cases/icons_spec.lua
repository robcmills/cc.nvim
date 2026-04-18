-- Tests for cc.icons: detection, icon-set selection, per-tool overrides,
-- default fallback, and rendering of the tool-header format "  <icon> Name:".
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
-- icon_set selection
-- ---------------------------------------------------------------------------
T['icon_set'] = MiniTest.new_set()

T['icon_set']['use_nerdfont=false forces unicode fallbacks'] = function()
  _G.child.lua([[
    require('cc.config').setup({ tool_icons = { use_nerdfont = false } })
    local icons = require('cc.icons')
    _G._set = icons.icon_set()
    _G._read = icons.for_tool('Read')
    _G._default = icons.for_tool('UnknownTool')
  ]])
  eq(_G.child.lua_get('_G._set == require("cc.icons")._UNICODE'), true)
  eq(_G.child.lua_get('_G._read'), '▤')
  -- Unknown tool falls back to default unicode glyph
  eq(_G.child.lua_get('_G._default'), '◆')
end

T['icon_set']['use_nerdfont=true forces nerdfont glyphs'] = function()
  _G.child.lua([[
    require('cc.config').setup({ tool_icons = { use_nerdfont = true } })
    local icons = require('cc.icons')
    _G._set = icons.icon_set()
    _G._read = icons.for_tool('Read')
  ]])
  eq(_G.child.lua_get('_G._set == require("cc.icons")._NERDFONT'), true)
  -- Nerdfont Read icon (U+F02D, UTF-8: EF 80 AD)
  eq(_G.child.lua_get('_G._read'), '\xef\x80\xad')
end

T['icon_set']['auto-detect when use_nerdfont=nil'] = function()
  -- In the minimal test env, mini.icons is not require-able (only mini.test
  -- and mini.doc land on rtp via the symlinked mini.nvim deps dir); but to
  -- keep this test robust, we just verify detect_nerdfont returns a boolean
  -- that the set matches.
  _G.child.lua([[
    require('cc.config').setup({})
    local icons = require('cc.icons')
    _G._detected = icons.detect_nerdfont()
    local set = icons.icon_set()
    _G._matches = (_G._detected and set == icons._NERDFONT)
                or (not _G._detected and set == icons._UNICODE)
  ]])
  eq(type(_G.child.lua_get('_G._detected')), 'boolean')
  eq(_G.child.lua_get('_G._matches'), true)
end

-- ---------------------------------------------------------------------------
-- Per-tool override and default fallback
-- ---------------------------------------------------------------------------
T['overrides'] = MiniTest.new_set()

T['overrides']['user-configured icon wins over built-in'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      tool_icons = {
        use_nerdfont = false,
        icons = { Read = '📖', Bash = '$' },
      },
    })
    local icons = require('cc.icons')
    _G._read = icons.for_tool('Read')
    _G._bash = icons.for_tool('Bash')
    -- Unconfigured tool still uses unicode default for that tool.
    _G._grep = icons.for_tool('Grep')
  ]])
  eq(_G.child.lua_get('_G._read'), '📖')
  eq(_G.child.lua_get('_G._bash'), '$')
  eq(_G.child.lua_get('_G._grep'), '⌕')
end

T['overrides']['user-configured default wins over built-in default'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      tool_icons = { use_nerdfont = false, default = '★' },
    })
    _G._unknown = require('cc.icons').for_tool('SomeMcpTool')
  ]])
  eq(_G.child.lua_get('_G._unknown'), '★')
end

T['overrides']['empty user default falls back to built-in default'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      tool_icons = { use_nerdfont = false, default = '' },
    })
    _G._unknown = require('cc.icons').for_tool('Nope')
  ]])
  eq(_G.child.lua_get('_G._unknown'), '◆')
end

-- ---------------------------------------------------------------------------
-- Rendering integration: tool header uses the icon and colon separator.
-- ---------------------------------------------------------------------------
T['rendering'] = MiniTest.new_set()

T['rendering']['unicode Read icon appears in tool header'] = function()
  helpers.render_fixture(_G.child, 'tool_read', { tool_icons = { use_nerdfont = false } })
  local lines = helpers.get_buffer_lines(_G.child)
  local found
  for _, line in ipairs(lines) do
    if line:match('^  ▤ Read: ') then found = line; break end
  end
  eq(type(found), 'string')
end

T['rendering']['user override icon appears in tool header'] = function()
  helpers.render_fixture(_G.child, 'tool_read', {
    tool_icons = { use_nerdfont = false, icons = { Read = '📖' } },
  })
  local lines = helpers.get_buffer_lines(_G.child)
  local found
  for _, line in ipairs(lines) do
    if line:match('^  📖 Read: ') then found = line; break end
  end
  eq(type(found), 'string')
end

T['rendering']['tool header uses colon (not em dash) after name'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local lines = helpers.get_buffer_lines(_G.child)
  local has_colon_form = false
  local em_dash_on_header = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+Read: ') then has_colon_form = true end
    -- Tool header must not carry an em dash; em dashes in file content are fine.
    if line:match('^%s+%S+%s+Read.*—') then em_dash_on_header = true end
  end
  eq(has_colon_form, true)
  eq(em_dash_on_header, false)
end

T['rendering']['nerdfont Bash icon appears when forced on'] = function()
  helpers.render_fixture(_G.child, 'tool_bash', { tool_icons = { use_nerdfont = true } })
  local lines = helpers.get_buffer_lines(_G.child)
  local found
  for _, line in ipairs(lines) do
    -- Nerdfont Bash = U+F120 (terminal glyph): UTF-8 \xef\x84\xa0
    if line:match('^  \xef\x84\xa0 Bash: ') then found = line; break end
  end
  eq(type(found), 'string')
end

T['rendering']['default icon used for unknown tool'] = function()
  -- Build a synthetic tool_use block with a tool name that isn't in the
  -- built-in icon table to verify the fallback path.
  _G.child.lua([[
    require('cc.config').setup({ tool_icons = { use_nerdfont = false } })
    local Output = require('cc.output')
    local Session = require('cc.session')
    local session = Session.new()
    local output = Output.new(session, 'cc-test-icons')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'tool_use', id = 'x1', name = 'FancyCustomTool' })
    output:on_content_block_stop({
      type = 'tool_use', id = 'x1', name = 'FancyCustomTool',
      input = { foo = 'bar' },
    })
    _G._test_bufnr = bufnr
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local found
  for _, line in ipairs(lines) do
    if line:match('^  ◆ FancyCustomTool: ') then found = line; break end
  end
  eq(type(found), 'string')
end

return T
