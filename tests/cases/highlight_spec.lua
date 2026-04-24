-- Tests for highlight groups — verify CcXxx groups are applied correctly.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

--- Check if a highlight group appears in the syntax stack at a position.
---@param child table
---@param row integer 1-based
---@param col integer 1-based
---@param group string expected highlight group name
local function assert_hl_in_stack(child, row, col, group)
  local stack = helpers.get_syn_stack(child, row, col)
  for _, name in ipairs(stack) do
    if name == group then return end
  end
  error(string.format('Highlight %q not in syntax stack at (%d,%d). Stack: %s',
    group, row, col, table.concat(stack, ', ')), 2)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

T['highlight_groups'] = MiniTest.new_set()

T['highlight_groups']['CcUser on User: line'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('User:') then
      local col = line:find('User')
      assert_hl_in_stack(_G.child, i, col, 'CcUser')
      return
    end
  end
  error('No User: line found')
end

T['highlight_groups']['CcAgent on Agent: line'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Agent:') then
      local col = line:find('Agent')
      assert_hl_in_stack(_G.child, i, col, 'CcAgent')
      return
    end
  end
  error('No Agent: line found')
end

T['highlight_groups']['CcTool on tool header line'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    local col = line:find('Read:')
    if col and line:match('^%s+%S+%s+Read:') then
      assert_hl_in_stack(_G.child, i, col, 'CcTool')
      return
    end
  end
  error('No Read tool header found')
end

-- Regression: MCP tool headers contain hyphens in the server name
-- (e.g. `mcp__claude-in-chrome__navigate`). The CcTool syntax pattern must
-- match those hyphens, not just \w.
T['highlight_groups']['CcTool on mcp__ tool header with hyphens'] = function()
  helpers.render_fixture(_G.child, 'mcp_chrome')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    local col = line:find('mcp__claude%-in%-chrome__')
    if col and line:match('^%s+%S+%s+mcp__claude%-in%-chrome__') then
      assert_hl_in_stack(_G.child, i, col, 'CcTool')
      return
    end
  end
  error('No mcp__claude-in-chrome__ tool header found')
end

T['highlight_groups']['CcOutput on Output: line'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Output:') then
      local col = line:find('Output')
      assert_hl_in_stack(_G.child, i, col, 'CcOutput')
      return
    end
  end
  error('No Output: line found')
end

-- Regression: headers appearing after a markdown region (e.g. a tool result
-- containing backticks/code fences opens markdownCodeBlock) must still win.
-- containedin=ALL on the CcXxx matches makes them fire even when nested
-- inside markdown regions.
T['highlight_groups']['CcTool wins after markdown region'] = function()
  helpers.render_fixture(_G.child, 'multi_turn')
  local lines = helpers.get_buffer_lines(_G.child)
  local tool_header_count = 0
  for i, line in ipairs(lines) do
    if line:match('^%s+%S+%s+%u%w*:') then
      tool_header_count = tool_header_count + 1
      if tool_header_count >= 2 then
        -- Find the column of the tool name (after icon + space).
        local col = line:find('%u%w*:')
        assert_hl_in_stack(_G.child, i, col, 'CcTool')
        return
      end
    end
  end
  error('multi_turn fixture expected to have at least 2 tool headers')
end

T['highlight_groups']['CcOutput wins after markdown region'] = function()
  helpers.render_fixture(_G.child, 'multi_turn')
  local lines = helpers.get_buffer_lines(_G.child)
  local output_count = 0
  for i, line in ipairs(lines) do
    if line:match('^%s+Output:%s*$') then
      output_count = output_count + 1
      if output_count >= 2 then
        local col = line:find('Output')
        assert_hl_in_stack(_G.child, i, col, 'CcOutput')
        return
      end
    end
  end
  error('multi_turn fixture expected to have at least 2 Output: headers')
end

T['highlight_groups']['CcDiffAdd syntax match is defined'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  -- Verify the syntax match exists (even if overridden by markdown regions)
  _G.child.lua([==[
    _G._test_syn_exists = vim.fn.hlexists('CcDiffAdd') == 1
  ]==])
  eq(_G.child.lua_get('_G._test_syn_exists'), true)
end

T['highlight_groups']['CcDiffDelete syntax match is defined'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  _G.child.lua([==[
    _G._test_syn_exists = vim.fn.hlexists('CcDiffDelete') == 1
  ]==])
  eq(_G.child.lua_get('_G._test_syn_exists'), true)
end

T['highlight_groups']['CcDiffHunk syntax match is defined'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  _G.child.lua([==[
    _G._test_syn_exists = vim.fn.hlexists('CcDiffHunk') == 1
  ]==])
  eq(_G.child.lua_get('_G._test_syn_exists'), true)
end

T['highlight_groups']['all default groups exist'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    require('cc.highlight').set_defaults()
    _G._hl_groups = {}
    local groups = {'CcUser', 'CcAgent', 'CcTool', 'CcOutput', 'CcError',
                    'CcCost', 'CcNotice', 'CcHook', 'CcPermission', 'CcCaret',
                    'CcDiffAdd', 'CcDiffDelete', 'CcDiffHunk'}
    for _, name in ipairs(groups) do
      local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
      _G._hl_groups[name] = ok and next(hl) ~= nil
    end
  ]==])
  local groups = _G.child.lua_get('_G._hl_groups')
  for name, exists in pairs(groups) do
    if not exists then
      error('Highlight group ' .. name .. ' is not defined')
    end
  end
end

return T
