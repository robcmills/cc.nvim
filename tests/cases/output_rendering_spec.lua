-- Tests for basic output rendering — user/agent turns, text, tool calls.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

--- Assert that a pattern appears somewhere in the concatenated buffer lines.
local function assert_buffer_contains(child, pattern)
  local lines = helpers.get_buffer_lines(child)
  local text = table.concat(lines, '\n')
  local found = text:find(pattern) ~= nil
  if not found then
    -- Provide helpful error message
    error(string.format(
      'Pattern %q not found in buffer (%d lines).\nFirst 20 lines:\n%s',
      pattern, #lines, table.concat(vim.list_slice(lines, 1, 20), '\n')
    ), 2)
  end
end

--- Assert that at least one buffer line matches a Lua pattern.
local function assert_any_line_matches(child, pattern)
  local lines = helpers.get_buffer_lines(child)
  for _, line in ipairs(lines) do
    if line:match(pattern) then return end
  end
  error(string.format(
    'No line matches pattern %q in buffer (%d lines).\nFirst 20 lines:\n%s',
    pattern, #lines, table.concat(vim.list_slice(lines, 1, 20), '\n')
  ), 2)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      _G.child = helpers.new_child()
    end,
    post_case = function()
      if _G.child then _G.child.stop() end
    end,
  },
})

-- ---------------------------------------------------------------------------
-- Simple text
-- ---------------------------------------------------------------------------
T['simple_text'] = MiniTest.new_set()

T['simple_text']['renders user and agent turns'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local lines = helpers.get_buffer_lines(_G.child)
  local has_user = false
  local has_agent = false
  for _, line in ipairs(lines) do
    if line:match('User:') then has_user = true end
    if line:match('Agent:') then has_agent = true end
  end
  eq(has_user, true)
  eq(has_agent, true)
end

T['simple_text']['user text appears in buffer'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  assert_buffer_contains(_G.child, 'apple banana cherry')
end

-- ---------------------------------------------------------------------------
-- Tool calls
-- ---------------------------------------------------------------------------
T['tool_read'] = MiniTest.new_set()

T['tool_read']['renders Read tool summary line'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  assert_any_line_matches(_G.child, 'Tool:.*Read')
end

T['tool_edit'] = MiniTest.new_set()

T['tool_edit']['renders Edit tool with diff markers'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  local lines = helpers.get_buffer_lines(_G.child)
  local has_diff_add = false
  local has_diff_del = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%+') then has_diff_add = true end
    if line:match('^%s+%-') then has_diff_del = true end
  end
  eq(has_diff_add, true)
  eq(has_diff_del, true)
end

T['tool_bash'] = MiniTest.new_set()

T['tool_bash']['renders Bash tool summary'] = function()
  helpers.render_fixture(_G.child, 'tool_bash')
  assert_any_line_matches(_G.child, 'Tool:.*Bash')
end

T['tool_grep'] = MiniTest.new_set()

T['tool_grep']['renders Grep tool summary'] = function()
  helpers.render_fixture(_G.child, 'tool_grep')
  assert_any_line_matches(_G.child, 'Tool:.*Grep')
end

T['tool_write'] = MiniTest.new_set()

T['tool_write']['renders Write tool summary'] = function()
  helpers.render_fixture(_G.child, 'tool_write')
  assert_any_line_matches(_G.child, 'Tool:.*Write')
end

-- ---------------------------------------------------------------------------
-- Multi-turn
-- ---------------------------------------------------------------------------
T['multi_turn'] = MiniTest.new_set()

T['multi_turn']['renders multiple turns with tools'] = function()
  helpers.render_fixture(_G.child, 'multi_turn')
  assert_any_line_matches(_G.child, 'Agent:')
  assert_any_line_matches(_G.child, 'Tool:')
end

-- ---------------------------------------------------------------------------
-- Visual dump (Layer C) — verify it works
-- ---------------------------------------------------------------------------
T['visual_dump'] = MiniTest.new_set()

T['visual_dump']['produces readable dump for simple_text'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local dump = helpers.visual_dump(_G.child)
  -- Should be a non-empty string with our format markers
  eq(type(dump), 'string')
  eq(dump:find('cc%-output') ~= nil, true)
end

return T
