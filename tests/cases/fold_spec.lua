-- Tests for fold levels and progressive disclosure.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

T['fold_levels'] = MiniTest.new_set()

T['fold_levels']['user header gets >1'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local fl = helpers.get_fold_levels(_G.child)
  -- Find the User: line and check its fold level
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('User:') then
      eq(fl[i], '>1')
      return
    end
  end
  error('No User: line found')
end

T['fold_levels']['agent header gets >1'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Agent:') then
      eq(fl[i], '>1')
      return
    end
  end
  error('No Agent: line found')
end

T['fold_levels']['agent text gets level 1'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('apple banana cherry') then
      eq(fl[i], 1)
      return
    end
  end
  error('No text line found')
end

T['fold_levels']['tool header gets >2'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Tool:.*Read') then
      eq(fl[i], '>2')
      return
    end
  end
  error('No Tool: Read line found')
end

T['fold_levels']['tool result header gets >3'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Output:') then
      eq(fl[i], '>3')
      return
    end
  end
  error('No Output: line found')
end

T['fold_levels']['tool result content gets level 3'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  -- Find a line after Output: that has content
  local after_output = false
  for i, line in ipairs(lines) do
    if line:match('Output:') then
      after_output = true
    elseif after_output and line:match('%S') then
      eq(fl[i], 3)
      return
    end
  end
  error('No content line after Output: found')
end

T['fold_levels']['edit diff lines get level 2'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('^%s+@@') then
      eq(fl[i], 2)
      return
    end
  end
  error('No @@ hunk header found in edit diff')
end

return T
