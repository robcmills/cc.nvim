-- Tests for diff rendering — Edit, Write, MultiEdit tool output.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

T['edit_diff'] = MiniTest.new_set()

T['edit_diff']['has hunk header'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('@@.*@@') then found = true; break end
  end
  eq(found, true)
end

T['edit_diff']['has add and delete lines'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  local lines = helpers.get_buffer_lines(_G.child)
  local adds, dels = 0, 0
  for _, line in ipairs(lines) do
    if line:match('^%s+%+') and not line:match('^%s+%+%+%+') then adds = adds + 1 end
    if line:match('^%s+%-') and not line:match('^%s+%-%-%-') then dels = dels + 1 end
  end
  eq(adds > 0, true)
  eq(dels > 0, true)
end

T['edit_diff']['diff lines are 8-space indented'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  local lines = helpers.get_buffer_lines(_G.child)
  for _, line in ipairs(lines) do
    if line:match('@@.*@@') then
      -- Hunk headers should start with 8 spaces
      eq(line:sub(1, 8), '        ')
      return
    end
  end
  error('No hunk header found')
end

T['write_diff'] = MiniTest.new_set()

T['write_diff']['has tool summary'] = function()
  helpers.render_fixture(_G.child, 'tool_write')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('Tool:.*Write') then found = true; break end
  end
  eq(found, true)
end

T['write_diff']['write has all-add lines'] = function()
  helpers.render_fixture(_G.child, 'tool_write')
  local lines = helpers.get_buffer_lines(_G.child)
  local adds = 0
  local dels = 0
  for _, line in ipairs(lines) do
    if line:match('^%s+%+ ') then adds = adds + 1 end
    if line:match('^%s+%- ') then dels = dels + 1 end
  end
  -- Write tool produces all-add diff (no deletions)
  eq(adds > 0, true)
  eq(dels, 0)
end

return T
