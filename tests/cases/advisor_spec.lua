-- Advisor tool blocks: server_tool_use (name "advisor") + advisor_tool_result.
-- Fixtures: advisor_redacted, advisor_two_calls, advisor_subagent and the
-- advisor.jsonl resume transcript are trimmed live captures (CLI 2.1.321).
-- Every live result came back redacted, so advisor_result_*,
-- advisor_declined* and advisor_error are advisor_redacted with only the
-- result content swapped for the shapes the CLI's renderer handles.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

local function text(lines) return table.concat(lines, '\n') end

local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then return i, l end
  end
  return nil
end

local function expect_clean(child, lines)
  eq(helpers.implicit_fold_violations(child), {})
  eq(find_line(lines, 'encrypted_content') == nil, true)
  eq(find_line(lines, 'Er8D') == nil, true) -- opaque payload prefix
end

-- ---------------------------------------------------------------------------
T['classify'] = MiniTest.new_set()

T['classify']['maps every content shape'] = function()
  local got = _G.child.lua_get([[(function()
    local A = require('cc.output.advisor')
    local function c(x) local o = A.classify(x); return { o.status, o.summary or vim.NIL, o.text or vim.NIL, o.is_error } end
    return {
      c({ type = 'advisor_result', text = 'Do X.' }),
      c({ type = 'advisor_redacted_result', encrypted_content = 'abc' }),
      c({ type = 'advisor_result', text = 'Out of scope.', stop_reason = 'refusal' }),
      c({ type = 'advisor_redacted_result', encrypted_content = 'abc', stop_reason = 'refusal' }),
      c({ type = 'advisor_tool_result_error', error_code = 'overloaded' }),
      c({ type = 'advisor_tool_result_error' }),
      c({ type = 'advisor_result', text = vim.NIL }),
      c({ type = 'something_new' }),
      c(nil),
    }
  end)()]])
  eq(got, {
    { 'reviewed', 'reviewed', 'Do X.', false },
    { 'redacted', 'reviewed (guidance encrypted)', vim.NIL, false },
    { 'declined', 'declined to advise on this request', 'Out of scope.', false },
    { 'declined', 'declined to advise on this request', vim.NIL, false },
    { 'unavailable', 'unavailable (overloaded)', vim.NIL, true },
    { 'unavailable', 'unavailable (unknown)', vim.NIL, true },
    { 'reviewed', 'reviewed', vim.NIL, false },
    { 'unknown', vim.NIL, vim.NIL, false },
    { 'unknown', vim.NIL, vim.NIL, false },
  })
end

-- ---------------------------------------------------------------------------
T['streaming'] = MiniTest.new_set()

T['streaming']['in progress: header shows progress and a running timer'] = function()
  helpers.replay_streaming(_G.child, 'advisor_in_progress')
  local lines = helpers.get_buffer_lines(_G.child)
  local lnum, line = find_line(lines, 'Advisor: reviewing the conversation')
  eq(lnum ~= nil, true)
  eq(helpers.get_fold_levels(_G.child)[lnum], '>2')
  eq(_G.child.lua_get([[require('cc.output')._buf_state[_G._test_bufnr]
    .tool_blocks['srvtoolu_014nQBhjxxsuRMYThPZ9W1iL'].running]]), true)
  eq(line:find('{}', 1, true), nil) -- empty input is not rendered
  expect_clean(_G.child, lines)
  _G.child.lua('_G._test_output:stop_all_tool_timers()')
end

T['streaming']['redacted: reviewed header, no body, blank before the answer'] = function()
  helpers.replay_streaming(_G.child, 'advisor_redacted')
  local lines = helpers.get_buffer_lines(_G.child)
  local lnum = find_line(lines, 'Advisor: reviewed (guidance encrypted)')
  eq(lnum ~= nil, true)
  eq(lines[lnum + 1], '')
  eq(lines[lnum + 2], '  2 + 2 equals 4.')
  eq(_G.child.lua_get([[require('cc.output')._buf_state[_G._test_bufnr]
    .tool_blocks['srvtoolu_014nQBhjxxsuRMYThPZ9W1iL'].running]]), vim.NIL)
  expect_clean(_G.child, lines)
end

T['streaming']['readable guidance renders in a Guidance fold'] = function()
  helpers.replay_streaming(_G.child, 'advisor_result_short')
  local lines = helpers.get_buffer_lines(_G.child)
  local lnum = find_line(lines, 'Advisor: reviewed')
  eq(lines[lnum]:find('encrypted', 1, true), nil)
  eq(lines[lnum + 1], '    Guidance:')
  eq(lines[lnum + 2], '      The answer is 4. Just state it; no caveats needed.')
  local levels = helpers.get_fold_levels(_G.child)
  eq(levels[lnum + 1], '>3')
  eq(levels[lnum + 2], 3)
  expect_clean(_G.child, lines)
end

T['streaming']['long guidance keeps every line inside the fold'] = function()
  helpers.replay_streaming(_G.child, 'advisor_result_long')
  local lines = helpers.get_buffer_lines(_G.child)
  local first = find_line(lines, 'Guidance:')
  local last = find_line(lines, 'When you are done, stop.')
  local levels = helpers.get_fold_levels(_G.child)
  for l = first + 1, last do eq(levels[l], 3) end
  expect_clean(_G.child, lines)
end

T['streaming']['declined without reason has no body'] = function()
  helpers.replay_streaming(_G.child, 'advisor_declined')
  local lines = helpers.get_buffer_lines(_G.child)
  local lnum = find_line(lines, 'Advisor: declined to advise on this request')
  eq(lnum ~= nil, true)
  eq(lines[lnum + 1], '')
  expect_clean(_G.child, lines)
end

T['streaming']['declined with reason shows the reason, not guidance'] = function()
  helpers.replay_streaming(_G.child, 'advisor_declined_reason')
  local lines = helpers.get_buffer_lines(_G.child)
  local lnum = find_line(lines, 'Advisor: declined to advise on this request')
  eq(lines[lnum + 1], '    Reason:')
  eq(lines[lnum + 2], '      This request is outside what the advisor can review.')
  eq(find_line(lines, 'Guidance:'), nil)
  expect_clean(_G.child, lines)
end

T['streaming']['unavailable shows the error code'] = function()
  helpers.replay_streaming(_G.child, 'advisor_error')
  local lines = helpers.get_buffer_lines(_G.child)
  eq(find_line(lines, 'Advisor: unavailable (overloaded)') ~= nil, true)
  expect_clean(_G.child, lines)
end

T['streaming']['two calls in one message resolve by tool_use_id into a group'] = function()
  helpers.replay_streaming(_G.child, 'advisor_two_calls')
  local lines = helpers.get_buffer_lines(_G.child)
  eq(find_line(lines, 'Work: 2 tool calls') ~= nil, true)
  local n = 0
  for _, l in ipairs(lines) do
    if l:find('Advisor: reviewed (guidance encrypted)', 1, true) then n = n + 1 end
    eq(l:find('reviewing the conversation', 1, true), nil)
  end
  eq(n, 2)
  expect_clean(_G.child, lines)
end

T['streaming']['a duplicate result renders once'] = function()
  helpers.replay_streaming(_G.child, 'advisor_result_short')
  local before = helpers.get_buffer_lines(_G.child)
  _G.child.lua([[_G._test_output:render_advisor_result('srvtoolu_014nQBhjxxsuRMYThPZ9W1iL',
    { type = 'advisor_result', text = 'second copy' })]])
  eq(helpers.get_buffer_lines(_G.child), before)
end

T['streaming']['subagent advisor call nests under Activity'] = function()
  helpers.replay_streaming(_G.child, 'advisor_subagent')
  local lines = helpers.get_buffer_lines(_G.child)
  local act = find_line(lines, 'Activity:')
  local lnum, line = find_line(lines, 'Advisor: reviewed (guidance encrypted)')
  eq(lnum, act + 1)
  eq(line:match('^%s*'), string.rep(' ', 6))
  eq(helpers.get_fold_levels(_G.child)[lnum], '>4')
  expect_clean(_G.child, lines)
end

T['streaming']['advisor between two Bash calls (live capture) joins the group'] = function()
  helpers.replay_streaming(_G.child, 'advisor_with_bash')
  local lines = helpers.get_buffer_lines(_G.child)
  eq(find_line(lines, 'Work: 3 tool calls') ~= nil, true)
  local one = find_line(lines, 'Bash: Print one')
  local adv = find_line(lines, 'Advisor: reviewed (guidance encrypted)')
  local two = find_line(lines, 'Bash: Print two')
  eq(one < adv and adv < two, true)
  eq(lines[one]:find('0ms', 1, true) ~= nil, true) -- first Bash keeps its duration
  for i = 2, #lines do eq(lines[i] == '' and lines[i - 1] == '', false) end
  expect_clean(_G.child, lines)
end

T['streaming']['two readable results each land under their own call'] = function()
  helpers.replay_streaming(_G.child, 'advisor_two_calls_readable')
  local lines = helpers.get_buffer_lines(_G.child)
  local first = find_line(lines, 'First review: answer directly.')
  local second = find_line(lines, 'Second review: Paris, one sentence.')
  local headers = {}
  for i, l in ipairs(lines) do
    if l:find('Advisor: reviewed', 1, true) then headers[#headers + 1] = i end
  end
  eq(#headers, 2)
  eq(headers[1] < first and first < headers[2] and headers[2] < second, true)
  expect_clean(_G.child, lines)
end

T['streaming']['Guidance/Reason labels use the result highlight'] = function()
  helpers.replay_streaming(_G.child, 'advisor_declined_reason')
  _G.child.lua([[require('cc.highlight').apply_buffer_syntax(_G._test_bufnr)]])
  local lines = helpers.get_buffer_lines(_G.child)
  local lnum = find_line(lines, 'Reason:')
  local function syn_at(row, col) return helpers.get_hl_at(_G.child, row, col) end
  eq(syn_at(lnum, 5), 'CcOutput')
end

T['streaming']['unavailable header uses the error highlight'] = function()
  local function syn_at(row, col) return helpers.get_hl_at(_G.child, row, col) end
  helpers.replay_streaming(_G.child, 'advisor_error')
  _G.child.lua([[require('cc.highlight').apply_buffer_syntax(_G._test_bufnr)]])
  local lines = helpers.get_buffer_lines(_G.child)
  local h, line = find_line(lines, 'Advisor: unavailable')
  eq(syn_at(h, line:find('unavailable', 1, true)), 'CcError')
end

-- ---------------------------------------------------------------------------
T['resume'] = MiniTest.new_set()

T['resume']['replays the advisor call from the transcript'] = function()
  helpers.render_fixture(_G.child, 'advisor_resume')
  local lines = helpers.get_buffer_lines(_G.child)
  local lnum = find_line(lines, 'Advisor: reviewed (guidance encrypted)')
  eq(lnum ~= nil, true)
  eq(lines[lnum + 1], '')
  eq(lines[lnum + 2], '  2 + 2 equals 4.')
  expect_clean(_G.child, lines)
end

T['resume']['replays advisor between two Bash calls'] = function()
  helpers.render_fixture(_G.child, 'advisor_with_bash_resume')
  local lines = helpers.get_buffer_lines(_G.child)
  eq(find_line(lines, 'Work: 3 tool calls') ~= nil, true)
  eq(find_line(lines, 'Advisor: reviewed (guidance encrypted)') ~= nil, true)
  expect_clean(_G.child, lines)
end

return T
