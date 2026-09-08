-- Tests for surfacing CLI error-shaped messages: rate_limit_event, synthetic
-- API-error assistant messages, and error results.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Lines in the output buffer matching a plain-text needle.
local function matching_lines(child, needle)
  local out = {}
  for _, line in ipairs(helpers.get_buffer_lines(child)) do
    if line:find(needle, 1, true) then table.insert(out, line) end
  end
  return out
end

local function format_rate_limit(child, info, prev)
  return child.lua_get(string.format(
    [[require('cc.output.error_notice').format_rate_limit(%s, %s)]],
    vim.inspect(info), prev and string.format('%q', prev) or 'nil'))
end

-- ---------------------------------------------------------------------------
-- Pure formatters
-- ---------------------------------------------------------------------------
T['format_rate_limit'] = MiniTest.new_set()

T['format_rate_limit']['rejected names the window and reset time'] = function()
  local text = format_rate_limit(_G.child,
    { status = 'rejected', rateLimitType = 'five_hour', resetsAt = 1757350800 })
  eq(text:match('^Usage limit reached %(5%-hour%) · resets %d') ~= nil, true, text)
end

T['format_rate_limit']['warning includes utilization'] = function()
  local text = format_rate_limit(_G.child,
    { status = 'allowed_warning', rateLimitType = 'seven_day', utilization = 0.9 })
  eq(text, 'Approaching usage limit (7-day) · 90% used')
end

T['format_rate_limit']['allowed is silent unless a limit was active'] = function()
  eq(format_rate_limit(_G.child, { status = 'allowed' }), vim.NIL)
  eq(format_rate_limit(_G.child, { status = 'allowed' }, 'allowed'), vim.NIL)
  eq(format_rate_limit(_G.child, { status = 'allowed' }, 'rejected'), 'Usage limit lifted')
  eq(format_rate_limit(_G.child, { status = 'allowed' }, 'allowed_warning'), 'Usage limit lifted')
end

T['format_rate_limit']['mentions extra usage and tolerates missing fields'] = function()
  eq(format_rate_limit(_G.child, { status = 'rejected', isUsingOverage = true }),
    'Usage limit reached · using extra usage')
  eq(format_rate_limit(_G.child, { status = 'bogus' }), vim.NIL)
  eq(format_rate_limit(_G.child, 'not a table'), vim.NIL)
end

T['format_errors'] = MiniTest.new_set()

T['format_errors']['assistant error keeps an existing Error prefix'] = function()
  local text = _G.child.lua_get([[require('cc.output.error_notice').format_assistant_error({
    error = 'max_output_tokens',
    message = { content = { { type = 'text',
      text = "API Error: Claude's response exceeded the 32000 output token maximum.\nSet CLAUDE_CODE_MAX_OUTPUT_TOKENS." } } },
  })]])
  eq(text, "API Error: Claude's response exceeded the 32000 output token maximum. Set CLAUDE_CODE_MAX_OUTPUT_TOKENS.")
end

T['format_errors']['assistant error with no text falls back to the error kind'] = function()
  local text = _G.child.lua_get([[require('cc.output.error_notice').format_assistant_error({
    error = 'authentication_failed',
    message = { content = { { type = 'text', text = 'No response requested.' } } },
  })]])
  eq(text, 'Error: authentication failed')
end

T['format_errors']['result error prefers errors, then result, then subtype'] = function()
  local E = [[require('cc.output.error_notice').format_result_error(%s)]]
  eq(_G.child.lua_get(E:format([[{ is_error = true, errors = { 'boom' }, result = 'x' }]])), 'Error: boom')
  eq(_G.child.lua_get(E:format([[{ is_error = true, subtype = 'success', result = 'bad' }]])), 'Error: bad')
  eq(_G.child.lua_get(E:format([[{ is_error = true, subtype = 'error_max_turns', errors = {} }]])),
    'Error: max turns reached')
  eq(_G.child.lua_get(E:format([[{ is_error = false, errors = { 'ignored' } }]])), vim.NIL)
end

-- ---------------------------------------------------------------------------
-- Streaming path
-- ---------------------------------------------------------------------------
T['rate_limit_event'] = MiniTest.new_set()

T['rate_limit_event']['renders warning, rejection, and lift once each'] = function()
  helpers.replay_streaming(_G.child, 'rate_limit')
  eq(#matching_lines(_G.child, 'Approaching usage limit (5-hour) · 90% used'), 1)
  eq(#matching_lines(_G.child, 'Usage limit reached (5-hour)'), 1)
  eq(#matching_lines(_G.child, 'Usage limit lifted'), 1)
  -- The initial `allowed` event before any limit renders nothing.
  local lines = helpers.get_buffer_lines(_G.child)
  local first_notice
  for i, line in ipairs(lines) do
    if line:find('──', 1, true) then first_notice = line; break end
  end
  eq(first_notice ~= nil and first_notice:find('Approaching', 1, true) ~= nil, true,
    'first notice was: ' .. tostring(first_notice))
end

T['rate_limit_event']['without rate_limit_info is ignored'] = function()
  helpers.replay_streaming(_G.child, 'api_retry')
  _G.child.lua([[_G._test_router:dispatch({ type = 'rate_limit_event' })]])
  eq(#matching_lines(_G.child, 'sage limit'), 0)
end

T['assistant_error'] = MiniTest.new_set()

T['assistant_error']['renders the synthetic error text once'] = function()
  helpers.replay_streaming(_G.child, 'assistant_error')
  local hits = matching_lines(_G.child, "Error: You've hit your limit · resets 3pm")
  eq(#hits, 1, vim.inspect(helpers.get_buffer_lines(_G.child)))
  eq(hits[1]:match('^%s*── .* ──%s*$') ~= nil, true, hits[1])
end

T['assistant_error']['still renders the cost line and ends the turn'] = function()
  helpers.replay_streaming(_G.child, 'assistant_error')
  eq(#matching_lines(_G.child, '$0.0020'), 1)
  eq(_G.child.lua_get('_G._test_session.turn_active'), false)
  eq(_G.child.lua_get('_G._test_router.last_error_text'), vim.NIL)
end

T['assistant_error']['streamed assistant messages are not re-rendered'] = function()
  helpers.replay_streaming(_G.child, 'api_retry')
  _G.child.lua([[_G._test_router:dispatch({ type = 'assistant', parent_tool_use_id = vim.NIL,
    message = { role = 'assistant', content = { { type = 'text', text = 'Response after retry.' } } } })]])
  eq(#matching_lines(_G.child, 'Response after retry.'), 1)
  eq(#matching_lines(_G.child, 'Error:'), 0)
end

T['assistant_error']['error notice line gets CcError highlight'] = function()
  helpers.replay_streaming(_G.child, 'assistant_error')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:find("Error: You've hit", 1, true) then
      local col = line:find('Error', 1, true)
      local stack = helpers.get_syn_stack(_G.child, i, col)
      eq(vim.tbl_contains(stack, 'CcError'), true, table.concat(stack, ', '))
      return
    end
  end
  error('error notice line not found')
end

T['result_error'] = MiniTest.new_set()

T['result_error']['renders errors[1] on one line'] = function()
  helpers.replay_streaming(_G.child, 'result_error')
  eq(#matching_lines(_G.child, 'Error: Something broke in the CLI'), 1)
end

return T
