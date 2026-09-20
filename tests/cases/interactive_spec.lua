-- Tests for interactive features — AskUserQuestion, plan mode, MCP tools.
-- Covers JSONL rendering and real-window keyboard responses through the router.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
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

local prompt_cases = dofile('tests/fixtures/interactive_prompts.lua')

local function open_prompt(request)
  _G.child.lua(([==[
    require('cc.config').setup({})
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-output')
    _G._test_bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(_G._test_bufnr)
    _G._test_writes = {}
    local router
    local process = {
      write = function(_, msg)
        assert(next(router.open_prompts) == nil, 'prompt must clear before write')
        table.insert(_G._test_writes, msg)
      end,
    }
    local instance = { session = session, process = process }
    router = require('cc.router').new({ session = session, output = output,
      process = process, instance = instance })
    _G._test_router = router
    router:dispatch({ type = 'control_request', request_id = 'interactive', request = %s })
  ]==]):format(vim.inspect(request)))
end

T['keyboard'] = MiniTest.new_set()
for _, case in ipairs(prompt_cases) do
  T['keyboard'][case.name] = function()
    open_prompt(case.request)
    eq(_G.child.lua_get('_G._test_router.open_prompts.interactive ~= nil'), true)
    for _, key in ipairs(case.keys) do _G.child.type_keys(key) end
    _G.child.lua([[vim.wait(100, function() return #_G._test_writes > 0 end)]])
    eq(_G.child.lua_get('_G._test_writes'), { {
      type = 'control_response', response = {
        request_id = 'interactive', subtype = 'success', response = case.response,
      },
    } })
    eq(_G.child.lua_get('next(_G._test_router.open_prompts) == nil'), true)
    eq(_G.child.lua_get('_G._test_router.instance.awaiting_permission'), false)
    eq(_G.child.lua_get('_G._test_router.instance.awaiting_input'), false)
    eq(_G.child.lua_get([[vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative ~= ''
    end, vim.api.nvim_list_wins())]]), {})
  end
end

T['picker dismiss is silent and idempotent'] = function()
  _G.child.lua([[
    _G._test_choices = 0
    _G._test_handle = require('cc.picker').select({ 'one', 'two' }, {}, function()
      _G._test_choices = _G._test_choices + 1
    end)
    assert(vim.api.nvim_win_is_valid(_G._test_handle.winid))
    assert(vim.api.nvim_buf_is_valid(_G._test_handle.bufnr))
    _G._test_handle.dismiss()
    _G._test_handle.dismiss()
    vim.wait(30)
  ]])
  eq(_G.child.lua_get('_G._test_choices'), 0)
  eq(_G.child.lua_get('vim.api.nvim_win_is_valid(_G._test_handle.winid)'), false)
  eq(_G.child.lua_get('vim.api.nvim_buf_is_valid(_G._test_handle.bufnr)'), false)
end

T['picker dismiss suppresses a queued keyboard choice'] = function()
  _G.child.lua([[
    _G._test_choices = 0
    local handle = require('cc.picker').select({ 'one' }, {}, function()
      _G._test_choices = _G._test_choices + 1
    end)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(handle.bufnr, 'n')) do
      if map.lhs == '<CR>' then map.callback(); break end
    end
    handle.dismiss()
    vim.wait(30)
  ]])
  eq(_G.child.lua_get('_G._test_choices'), 0)
end

T['EnterPlanMode auto-approves without registering a prompt'] = function()
  open_prompt({ subtype = 'can_use_tool', tool_name = 'EnterPlanMode', tool_use_id = 'tool-1', input = {} })
  eq(_G.child.lua_get('_G._test_writes'), { {
    type = 'control_response', response = {
      request_id = 'interactive', subtype = 'success',
      response = { behavior = 'allow', updatedInput = {}, toolUseID = 'tool-1' },
    },
  } })
  eq(_G.child.lua_get('next(_G._test_router.open_prompts) == nil'), true)
end

T['synchronous empty questions do not leave a registered prompt'] = function()
  open_prompt({ subtype = 'can_use_tool', tool_name = 'AskUserQuestion', input = {} })
  eq(_G.child.lua_get('#_G._test_writes'), 1)
  eq(_G.child.lua_get('next(_G._test_router.open_prompts) == nil'), true)
end

T['picker opens in normal mode while the user is typing'] = function()
  _G.child.type_keys('i')
  _G.child.lua([[
    _G._test_handle = require('cc.picker').select({ 'one', 'two' }, {
      format_item = function(item) return 'Item: ' .. item end,
    }, function(item, idx) _G._test_choice = { item, idx } end)
  ]])
  _G.child.type_keys('j', '<CR>')
  _G.child.lua([[vim.wait(100, function() return _G._test_choice ~= nil end)]])
  eq(_G.child.lua_get('_G._test_choice'), { 'two', 2 })
  eq(_G.child.lua_get('vim.api.nvim_win_is_valid(_G._test_handle.winid)'), false)
end

return T
