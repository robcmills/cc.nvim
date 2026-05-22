-- Tests for router._handle_permission_request — the can_use_tool response
-- shape across the four user choices (Allow / Always / Deny / Cancel).
--
-- Drives the router directly with a mock process that captures outbound
-- control_response writes, and stubs cc.permission_prompt.ask so we don't
-- need a floating window. The CLI side of this protocol is described by
-- claude-code/src/entrypoints/sdk/coreSchemas.ts (PermissionResultSchema)
-- and structuredIO.ts:815 (persistPermissionUpdates path).

local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Drive a single can_use_tool dispatch in the child. `prompt_args` is a Lua
--- expression that evaluates to `{ behavior = ..., variant = ... }`; that's
--- what cc.permission_prompt.ask is stubbed to feed to its callback. The
--- written control_response body is exposed as _G._test_response.
local function dispatch(child, req_lua, prompt_args)
  child.lua(([==[
    local Router = require('cc.router')
    local Session = require('cc.session')
    local Output = require('cc.output')

    _G._test_writes = {}
    local mock_process = {
      write = function(_, msg) table.insert(_G._test_writes, msg) end,
      is_alive = function() return true end,
    }

    -- Replace ask() so we synchronously deliver the desired choice.
    package.loaded['cc.permission_prompt'] = nil
    require('cc.permission_prompt').ask = function(_tool, _input, on_choice)
      local choice = %s
      on_choice(choice.behavior, choice.variant)
    end

    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    output:ensure_buffer()
    -- Stub renderers so we don't need a window or to clutter test buffer.
    output.render_permission_request = function() end
    output.render_permission_outcome = function() end

    local router = Router.new({
      session = session,
      output = output,
      process = mock_process,
    })

    router:dispatch({
      type = 'control_request',
      request_id = 'req-test-1',
      request = %s,
    })

    _G._test_response = _G._test_writes[1]
        and _G._test_writes[1].response
        and _G._test_writes[1].response.response
        or nil
  ]==]):format(prompt_args, req_lua))
end

local SUGGESTIONS_LUA = [[{
  {
    type = 'addRules',
    rules = { { toolName = 'Bash', ruleContent = 'ls:*' } },
    behavior = 'allow',
    destination = 'localSettings',
  },
}]]

local REQ_WITH_SUGGESTIONS = [[{
  subtype = 'can_use_tool',
  tool_name = 'Bash',
  input = { command = 'ls -la' },
  tool_use_id = 'tu-1',
  permission_suggestions = ]] .. SUGGESTIONS_LUA .. [[,
}]]

local REQ_WITHOUT_SUGGESTIONS = [[{
  subtype = 'can_use_tool',
  tool_name = 'mcp__example__do_thing',
  input = { x = 1 },
  tool_use_id = 'tu-2',
}]]

T['allow_once sends plain allow with user_temporary classification'] = function()
  dispatch(_G.child, REQ_WITH_SUGGESTIONS,
    [[{ behavior = 'allow', variant = 'allow_once' }]])
  local resp = _G.child.lua_get('_G._test_response')
  eq(resp.behavior, 'allow')
  eq(resp.toolUseID, 'tu-1')
  eq(resp.updatedInput, { command = 'ls -la' })
  eq(resp.decisionClassification, 'user_temporary')
  -- Allow-once must NOT carry updatedPermissions, even when suggestions exist.
  eq(resp.updatedPermissions, nil)
end

T['allow_always echoes permission_suggestions back as updatedPermissions'] = function()
  dispatch(_G.child, REQ_WITH_SUGGESTIONS,
    [[{ behavior = 'allow', variant = 'allow_always' }]])
  local resp = _G.child.lua_get('_G._test_response')
  eq(resp.behavior, 'allow')
  eq(resp.decisionClassification, 'user_permanent')
  eq(#resp.updatedPermissions, 1)
  local upd = resp.updatedPermissions[1]
  eq(upd.type, 'addRules')
  eq(upd.behavior, 'allow')
  eq(upd.destination, 'localSettings')
  eq(upd.rules[1].toolName, 'Bash')
  eq(upd.rules[1].ruleContent, 'ls:*')
end

T['allow_always synthesizes a tool-wide rule when no suggestions provided'] = function()
  dispatch(_G.child, REQ_WITHOUT_SUGGESTIONS,
    [[{ behavior = 'allow', variant = 'allow_always' }]])
  local resp = _G.child.lua_get('_G._test_response')
  eq(resp.behavior, 'allow')
  eq(resp.decisionClassification, 'user_permanent')
  eq(#resp.updatedPermissions, 1)
  local upd = resp.updatedPermissions[1]
  eq(upd.type, 'addRules')
  eq(upd.behavior, 'allow')
  eq(upd.destination, 'localSettings')
  eq(#upd.rules, 1)
  eq(upd.rules[1].toolName, 'mcp__example__do_thing')
  -- No ruleContent means the rule matches the whole tool, like upstream's
  -- FallbackPermissionRequest "Yes, don't ask again" payload.
  eq(upd.rules[1].ruleContent, nil)
end

T['deny sends deny with user_reject classification'] = function()
  dispatch(_G.child, REQ_WITH_SUGGESTIONS,
    [[{ behavior = 'deny', variant = 'deny' }]])
  local resp = _G.child.lua_get('_G._test_response')
  eq(resp.behavior, 'deny')
  eq(resp.toolUseID, 'tu-1')
  eq(resp.decisionClassification, 'user_reject')
  eq(resp.updatedPermissions, nil)
end

T['cancel sends deny (treated identically to explicit deny)'] = function()
  dispatch(_G.child, REQ_WITH_SUGGESTIONS,
    [[{ behavior = 'deny', variant = 'cancel' }]])
  local resp = _G.child.lua_get('_G._test_response')
  eq(resp.behavior, 'deny')
  eq(resp.decisionClassification, 'user_reject')
end

return T
