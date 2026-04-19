-- Tests for interactive features — AskUserQuestion, plan mode, MCP tools.
-- These test the JSONL rendering of these features (not the interactive UI flow).
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
-- AskUserQuestion
-- ---------------------------------------------------------------------------
T['ask_user_question'] = MiniTest.new_set()

T['ask_user_question']['renders tool summary'] = function()
  helpers.render_fixture(_G.child, 'ask_user_question')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+AskUserQuestion:') then found = true; break end
  end
  eq(found, true)
end

-- ---------------------------------------------------------------------------
-- Plan mode
-- ---------------------------------------------------------------------------
T['plan_mode'] = MiniTest.new_set()

T['plan_mode']['ExitPlanMode renders tool summary'] = function()
  helpers.render_fixture(_G.child, 'plan_mode')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+ExitPlanMode:') then found = true; break end
  end
  eq(found, true)
end

T['plan_mode']['EnterPlanMode renders tool summary'] = function()
  helpers.render_fixture(_G.child, 'enter_plan_mode')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+EnterPlanMode:') then found = true; break end
  end
  eq(found, true)
end

-- ---------------------------------------------------------------------------
-- Sub-agent
-- ---------------------------------------------------------------------------
T['subagent'] = MiniTest.new_set()

T['subagent']['Agent tool renders summary'] = function()
  helpers.render_fixture(_G.child, 'subagent')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+Subagent:') then found = true; break end
  end
  eq(found, true)
end

-- ---------------------------------------------------------------------------
-- MCP tools
-- ---------------------------------------------------------------------------
T['mcp_tools'] = MiniTest.new_set()

T['mcp_tools']['chrome tool renders summary'] = function()
  helpers.render_fixture(_G.child, 'mcp_chrome')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+mcp__claude%-in%-chrome') then found = true; break end
  end
  eq(found, true)
end

T['mcp_tools']['atlassian tool renders summary'] = function()
  helpers.render_fixture(_G.child, 'mcp_atlassian')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+mcp__claude_ai_Atlassian') then found = true; break end
  end
  eq(found, true)
end

T['mcp_tools']['slack tool renders summary'] = function()
  helpers.render_fixture(_G.child, 'mcp_slack')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+mcp__claude_ai_Slack') then found = true; break end
  end
  eq(found, true)
end

-- ---------------------------------------------------------------------------
-- Skill tool
-- ---------------------------------------------------------------------------
T['skill'] = MiniTest.new_set()

T['skill']['Skill tool renders summary'] = function()
  helpers.render_fixture(_G.child, 'skill')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+Skill:') then found = true; break end
  end
  eq(found, true)
end

-- ---------------------------------------------------------------------------
-- WebSearch
-- ---------------------------------------------------------------------------
T['websearch'] = MiniTest.new_set()

T['websearch']['WebSearch tool renders summary'] = function()
  helpers.render_fixture(_G.child, 'websearch')
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, line in ipairs(lines) do
    if line:match('^%s+%S+%s+WebSearch:') then found = true; break end
  end
  eq(found, true)
end

-- ---------------------------------------------------------------------------
-- Compact boundary
-- ---------------------------------------------------------------------------
T['compact_boundary'] = MiniTest.new_set()

T['compact_boundary']['fixture loads without error'] = function()
  -- compact_boundary fixture has system messages + user messages
  -- The system compact_boundary is not rendered by render_historical_record
  -- (history.read_transcript filters it out), so just verify no crash
  MiniTest.expect.no_error(function()
    helpers.render_fixture(_G.child, 'compact_boundary')
  end)
end

return T
