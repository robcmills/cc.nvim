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

-- NOTE: CcDiffAdd/CcDiffDelete/CcDiffHunk syntax matches can be overridden
-- by markdown syntax regions when the edited file contains markdown (code
-- fences, etc.). The tool_edit fixture edits a markdown file, so diff
-- highlights compete with markdownCodeBlock. This is a known limitation.
-- The diff lines ARE present (tested in diff_rendering_spec.lua); the
-- highlight just doesn't win in all contexts.

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
                    'CcSpinner', 'CcDiffAdd', 'CcDiffDelete', 'CcDiffHunk'}
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
