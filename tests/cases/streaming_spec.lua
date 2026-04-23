-- Tests for the streaming NDJSON path (parser -> router -> output).
-- These test the live streaming code path as opposed to the JSONL resume path.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

--- Assert that a pattern appears somewhere in the concatenated buffer lines.
local function assert_buffer_contains(child, pattern)
  local lines = helpers.get_buffer_lines(child)
  local text = table.concat(lines, '\n')
  if not text:find(pattern) then
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

--- Assert that NO buffer line matches a Lua pattern.
local function assert_no_line_matches(child, pattern)
  local lines = helpers.get_buffer_lines(child)
  for i, line in ipairs(lines) do
    if line:match(pattern) then
      error(string.format(
        'Line %d unexpectedly matches pattern %q: %s',
        i, pattern, line
      ), 2)
    end
  end
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
-- Simple text streaming
-- ---------------------------------------------------------------------------
T['simple_text'] = MiniTest.new_set()

T['simple_text']['renders agent header'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  assert_any_line_matches(_G.child, 'Agent:')
end

T['simple_text']['streams text deltas into buffer'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  assert_buffer_contains(_G.child, 'Hello world!')
end

T['simple_text']['renders result cost line'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  assert_any_line_matches(_G.child, '%$0%.0012')
end

T['simple_text']['session tracks cost'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  local state = helpers.get_session_state(_G.child)
  eq(state.cost_usd, 0.0012)
  eq(state.input_tokens, 150)
  eq(state.output_tokens, 8)
end

T['simple_text']['session records init'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  local state = helpers.get_session_state(_G.child)
  eq(state.id, 'test-stream-001')
  eq(state.model, 'claude-sonnet-4-20250514')
end

T['simple_text']['session is not streaming after message_stop'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  local state = helpers.get_session_state(_G.child)
  eq(state.is_streaming, false)
end

-- ---------------------------------------------------------------------------
-- Tool use (Bash) with streaming
-- ---------------------------------------------------------------------------
T['tool_bash'] = MiniTest.new_set()

T['tool_bash']['renders tool header'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Bash:')
end

T['tool_bash']['renders tool summary with command'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  assert_any_line_matches(_G.child, 'ls %-la')
end

T['tool_bash']['renders tool result output'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  assert_buffer_contains(_G.child, 'file1%.txt')
  assert_buffer_contains(_G.child, 'README%.md')
end

T['tool_bash']['renders follow-up text'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  assert_buffer_contains(_G.child, 'Here are the files')
end

T['tool_bash']['renders result cost line'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  assert_any_line_matches(_G.child, '%$0%.0054')
end

T['tool_bash']['tool_progress updates tool header with elapsed time'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  -- The tool_progress events should update the header with [2s]
  assert_any_line_matches(_G.child, '%[2s%]')
end

-- ---------------------------------------------------------------------------
-- Tool progress (elapsed time tracking)
-- ---------------------------------------------------------------------------
T['tool_progress'] = MiniTest.new_set()

T['tool_progress']['updates elapsed time on tool header'] = function()
  helpers.replay_streaming(_G.child, 'tool_progress')
  -- After 5 tool_progress events (1-5s), header should show [5s]
  assert_any_line_matches(_G.child, '%[5s%]')
end

T['tool_progress']['renders tool result'] = function()
  helpers.replay_streaming(_G.child, 'tool_progress')
  assert_buffer_contains(_G.child, 'done')
end

-- ---------------------------------------------------------------------------
-- Hook events (streaming-only)
-- ---------------------------------------------------------------------------
T['hook_events'] = MiniTest.new_set()

T['hook_events']['renders hook started line'] = function()
  helpers.replay_streaming(_G.child, 'hook_events')
  assert_any_line_matches(_G.child, 'Hook:.*PreToolUse.*started')
end

T['hook_events']['renders hook response with elapsed time'] = function()
  helpers.replay_streaming(_G.child, 'hook_events')
  assert_any_line_matches(_G.child, 'Hook:.*PreToolUse.*response.*1%.3s')
end

T['hook_events']['renders PostToolUse hook'] = function()
  helpers.replay_streaming(_G.child, 'hook_events')
  assert_any_line_matches(_G.child, 'Hook:.*PostToolUse')
end

T['hook_events']['renders tool and result alongside hooks'] = function()
  helpers.replay_streaming(_G.child, 'hook_events')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Edit:')
  assert_buffer_contains(_G.child, 'Edit applied')
end

-- ---------------------------------------------------------------------------
-- Subagent tasks (streaming-only)
-- ---------------------------------------------------------------------------
T['subagent_tasks'] = MiniTest.new_set()

T['subagent_tasks']['renders task started'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  assert_any_line_matches(_G.child, 'Task started')
end

T['subagent_tasks']['renders task done with summary'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  assert_any_line_matches(_G.child, 'Task done')
end

T['subagent_tasks']['renders Agent tool'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Subagent:')
end

T['subagent_tasks']['renders surrounding text blocks'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  assert_buffer_contains(_G.child, 'analyze the codebase')
  assert_buffer_contains(_G.child, 'analysis is complete')
end

-- ---------------------------------------------------------------------------
-- Thinking blocks
-- ---------------------------------------------------------------------------
T['thinking'] = MiniTest.new_set()

T['thinking']['renders thinking marker when show_thinking=true'] = function()
  helpers.replay_streaming(_G.child, 'thinking', { show_thinking = true })
  assert_any_line_matches(_G.child, '∴ thinking:')
end

T['thinking']['streams thinking content when show_thinking=true'] = function()
  helpers.replay_streaming(_G.child, 'thinking', { show_thinking = true })
  assert_buffer_contains(_G.child, 'think about')
  assert_buffer_contains(_G.child, 'this problem carefully')
end

T['thinking']['renders text block after thinking'] = function()
  helpers.replay_streaming(_G.child, 'thinking', { show_thinking = true })
  assert_buffer_contains(_G.child, 'Here is my answer')
end

T['thinking']['hides thinking when show_thinking=false (default)'] = function()
  helpers.replay_streaming(_G.child, 'thinking')
  local lines = _G.child.lua_get('vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false)')
  for _, line in ipairs(lines) do
    if line:match('∴ thinking:') then
      error('expected no thinking marker, got: ' .. line)
    end
    if line:match('think about') or line:match('this problem carefully') then
      error('expected no thinking content, got: ' .. line)
    end
  end
  assert_buffer_contains(_G.child, 'Here is my answer')
end

-- ---------------------------------------------------------------------------
-- Result / cost display
-- ---------------------------------------------------------------------------
T['result_cost'] = MiniTest.new_set()

T['result_cost']['renders cost in result line'] = function()
  helpers.replay_streaming(_G.child, 'result_cost')
  assert_any_line_matches(_G.child, '%$0%.1234')
end

T['result_cost']['renders token counts'] = function()
  helpers.replay_streaming(_G.child, 'result_cost')
  assert_any_line_matches(_G.child, '5000 in')
  assert_any_line_matches(_G.child, '200 out')
end

T['result_cost']['session tracks usage'] = function()
  helpers.replay_streaming(_G.child, 'result_cost')
  local state = helpers.get_session_state(_G.child)
  eq(state.cost_usd, 0.1234)
  eq(state.input_tokens, 5000)
  eq(state.output_tokens, 200)
end

-- ---------------------------------------------------------------------------
-- Result line: cache tokens, show_cost, cost_format
-- ---------------------------------------------------------------------------
--- Render a result line directly in the child with the given config.
--- Returns the text of the rendered line (or nil if nothing was rendered).
local function render_result_line(child, cfg_opts, result)
  child.lua(string.format([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup(%s)
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    output:render_result(%s)
    _G._test_bufnr = bufnr
  ]==], vim.inspect(cfg_opts or {}), vim.inspect(result)))
  local lines = helpers.get_buffer_lines(child)
  for _, line in ipairs(lines) do
    if line:match('──') then return line end
  end
  return nil
end

T['result_line'] = MiniTest.new_set()

T['result_line']['shows cache_creation and cache_read tokens (compact)'] = function()
  local line = render_result_line(_G.child, {}, {
    total_cost_usd = 0.5734,
    usage = {
      input_tokens = 5,
      output_tokens = 111,
      cache_creation_input_tokens = 76626,
      cache_read_input_tokens = 16257,
    },
  })
  assert(line, 'expected a result line')
  eq(line:find('5 in', 1, true) ~= nil, true)
  eq(line:find('111 out', 1, true) ~= nil, true)
  eq(line:find('76.6k cache write', 1, true) ~= nil, true)
  eq(line:find('16.3k cache read', 1, true) ~= nil, true)
end

T['result_line']['compact format strips .0 and keeps sub-1k raw'] = function()
  local line = render_result_line(_G.child, {}, {
    total_cost_usd = 0.01,
    usage = {
      input_tokens = 1,
      output_tokens = 1,
      cache_creation_input_tokens = 5000,
      cache_read_input_tokens = 999,
    },
  })
  assert(line, 'expected a result line')
  eq(line:find('5k cache write', 1, true) ~= nil, true)
  eq(line:find('999 cache read', 1, true) ~= nil, true)
end

T['result_line']['omits cache parts when zero'] = function()
  local line = render_result_line(_G.child, {}, {
    total_cost_usd = 0.01,
    usage = {
      input_tokens = 5,
      output_tokens = 10,
      cache_creation_input_tokens = 0,
      cache_read_input_tokens = 0,
    },
  })
  assert(line, 'expected a result line')
  eq(line:find('cache write', 1, true), nil)
  eq(line:find('cache read', 1, true), nil)
end

T['result_line']['show_turn_cost = false suppresses the line'] = function()
  local line = render_result_line(_G.child, { show_turn_cost = false }, {
    total_cost_usd = 0.01,
    usage = { input_tokens = 5, output_tokens = 10 },
  })
  eq(line, nil)
end

T['result_line']['turn_cost_format overrides the default text'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({
      turn_cost_format = function(r)
        return string.format('custom: $%.2f', r.total_cost_usd)
      end,
    })
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    output:render_result({ total_cost_usd = 1.23, usage = { input_tokens = 1, output_tokens = 2 } })
    _G._test_bufnr = bufnr
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local found
  for _, l in ipairs(lines) do if l:match('custom: %$1%.23') then found = l; break end end
  assert(found, 'expected custom cost_format output')
  eq(found:find('1 in', 1, true), nil)
end

T['result_line']['turn_cost_format returning nil falls back to default'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({ turn_cost_format = function() return nil end })
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    output:render_result({ total_cost_usd = 0.5, usage = { input_tokens = 3, output_tokens = 4 } })
    _G._test_bufnr = bufnr
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local found
  for _, l in ipairs(lines) do if l:match('%$0%.5000') then found = l; break end end
  assert(found, 'expected default format fallback')
  eq(found:find('3 in', 1, true) ~= nil, true)
  eq(found:find('4 out', 1, true) ~= nil, true)
end

T['result_line']['anchors to end of agent turn when tail has moved past'] = function()
  -- Simulates: resume prerender -> user submits new message before the
  -- subprocess result lands. Cost line should insert at end of agent turn,
  -- not at buffer tail (which is now inside the new user fold).
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    output:render_historical_record({ type = 'user_text', text = 'hello' })
    output:render_historical_record({
      type = 'assistant',
      blocks = { { type = 'text', text = 'Hi there' } },
    })
    output:render_user_turn('new question')
    output:render_result({
      total_cost_usd = 0.5734,
      usage = { input_tokens = 5, output_tokens = 111 },
    })

    _G._test_bufnr = bufnr
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local cost_idx, user2_idx, agent_content_idx
  for i, l in ipairs(lines) do
    if l:match('── %$0%.5734') then cost_idx = i end
    if l:match('new question') then user2_idx = i end
    if l:match('Hi there') then agent_content_idx = i end
  end
  assert(cost_idx, 'expected cost line')
  assert(user2_idx, 'expected new user content')
  assert(agent_content_idx, 'expected agent content')
  -- Cost line must sit between the agent content and the new user turn.
  eq(cost_idx > agent_content_idx, true)
  eq(cost_idx < user2_idx, true)
end

T['result_line']['turn_cost_format errors fall back to default'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({ turn_cost_format = function() error('boom') end })
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    output:render_result({ total_cost_usd = 0.25, usage = { input_tokens = 7, output_tokens = 8 } })
    _G._test_bufnr = bufnr
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local found
  for _, l in ipairs(lines) do if l:match('%$0%.2500') then found = l; break end end
  assert(found, 'expected default format fallback after error')
  eq(found:find('7 in', 1, true) ~= nil, true)
  eq(found:find('8 out', 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- Multi-block (text + multiple tools in sequence)
-- ---------------------------------------------------------------------------
T['multi_block'] = MiniTest.new_set()

T['multi_block']['renders text before first tool'] = function()
  helpers.replay_streaming(_G.child, 'multi_block')
  assert_buffer_contains(_G.child, 'check that file')
end

T['multi_block']['renders Read tool'] = function()
  helpers.replay_streaming(_G.child, 'multi_block')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Read:')
end

T['multi_block']['renders Bash tool'] = function()
  helpers.replay_streaming(_G.child, 'multi_block')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Bash:')
end

T['multi_block']['renders tool results'] = function()
  helpers.replay_streaming(_G.child, 'multi_block')
  assert_buffer_contains(_G.child, 'hello world')
  assert_buffer_contains(_G.child, 'confirmed')
end

T['multi_block']['renders final text'] = function()
  helpers.replay_streaming(_G.child, 'multi_block')
  assert_buffer_contains(_G.child, 'All done')
end

-- ---------------------------------------------------------------------------
-- Parallel tool_result race: a tool_result arriving while the next tool's
-- content_block is still streaming must still render Output: under the
-- correct tool's input — not between the next tool's header and its input.
-- ---------------------------------------------------------------------------
T['parallel_tool_result_race'] = MiniTest.new_set()

T['parallel_tool_result_race']['output lands under owning tool input, not next tool header'] = function()
  helpers.replay_streaming(_G.child, 'parallel_tool_result_race')
  local lines = helpers.get_buffer_lines(_G.child)

  -- Find each tool header and verify each Output: appears BEFORE the next tool header.
  local tool_header_rows = {}
  local output_header_rows = {}
  for i, line in ipairs(lines) do
    if line:match('^%s+%S+%s+Grep:') then
      table.insert(tool_header_rows, i)
    elseif line:match('^%s+Output:%s*$') then
      table.insert(output_header_rows, i)
    end
  end
  eq(#tool_header_rows, 3)
  eq(#output_header_rows, 3)

  -- Each tool N's Output must appear before tool N+1's header.
  if output_header_rows[1] > tool_header_rows[2] then
    error(string.format(
      'tool 1 Output (line %d) appears after tool 2 header (line %d):\n%s',
      output_header_rows[1], tool_header_rows[2], table.concat(lines, '\n')))
  end
  if output_header_rows[2] > tool_header_rows[3] then
    error(string.format(
      'tool 2 Output (line %d) appears after tool 3 header (line %d):\n%s',
      output_header_rows[2], tool_header_rows[3], table.concat(lines, '\n')))
  end
end

T['parallel_tool_result_race']['each result body is grouped with its owning tool'] = function()
  helpers.replay_streaming(_G.child, 'parallel_tool_result_race')
  local lines = helpers.get_buffer_lines(_G.child)

  local function line_of(pat)
    for i, l in ipairs(lines) do
      if l:find(pat, 1, true) then return i end
    end
    error('pattern not found: ' .. pat .. '\n' .. table.concat(lines, '\n'))
  end

  local first_body = line_of('README:first result body')
  local second_header = line_of('router.lua')
  local second_body = line_of('router:second result body')
  local third_header = line_of('FEATURE_AUDIT.md')
  local third_body = line_of('feature:third result body')

  -- Tool 1's result body must come before tool 2's input references router.lua.
  if first_body > second_header then
    error('tool 1 result appears after tool 2 input:\n' .. table.concat(lines, '\n'))
  end
  if second_body > third_header then
    error('tool 2 result appears after tool 3 input:\n' .. table.concat(lines, '\n'))
  end
  if not (first_body < second_body and second_body < third_body) then
    error('result bodies out of order:\n' .. table.concat(lines, '\n'))
  end
end

T['parallel_tool_result_race']['all three inputs and outputs render'] = function()
  helpers.replay_streaming(_G.child, 'parallel_tool_result_race')
  assert_buffer_contains(_G.child, 'README%.md')
  assert_buffer_contains(_G.child, 'router%.lua')
  assert_buffer_contains(_G.child, 'FEATURE_AUDIT%.md')
  assert_buffer_contains(_G.child, 'README:first result body')
  assert_buffer_contains(_G.child, 'router:second result body')
  assert_buffer_contains(_G.child, 'feature:third result body')
end

-- ---------------------------------------------------------------------------
-- API retry notice
-- ---------------------------------------------------------------------------
T['api_retry'] = MiniTest.new_set()

T['api_retry']['renders API retry notice'] = function()
  helpers.replay_streaming(_G.child, 'api_retry')
  assert_any_line_matches(_G.child, 'API retry')
end

T['api_retry']['renders response after retry'] = function()
  helpers.replay_streaming(_G.child, 'api_retry')
  assert_buffer_contains(_G.child, 'Response after retry')
end

-- ---------------------------------------------------------------------------
-- Compact boundary notice (streaming)
-- ---------------------------------------------------------------------------
T['compact_notice'] = MiniTest.new_set()

T['compact_notice']['renders compacting notice'] = function()
  helpers.replay_streaming(_G.child, 'compact_notice')
  assert_any_line_matches(_G.child, 'Compacting context')
end

T['compact_notice']['renders compact boundary notice'] = function()
  helpers.replay_streaming(_G.child, 'compact_notice')
  assert_any_line_matches(_G.child, 'Context Compacted')
end

T['compact_notice']['renders text before and after compaction'] = function()
  helpers.replay_streaming(_G.child, 'compact_notice')
  assert_buffer_contains(_G.child, 'First response')
  assert_buffer_contains(_G.child, 'Continuing after compaction')
end

-- ---------------------------------------------------------------------------
-- Plan mode (streaming-only: EnterPlanMode tool)
-- ---------------------------------------------------------------------------
T['plan_mode'] = MiniTest.new_set()

T['plan_mode']['renders thinking block when show_thinking=true'] = function()
  helpers.replay_streaming(_G.child, 'plan_mode', { show_thinking = true })
  assert_any_line_matches(_G.child, '∴ thinking:')
end

T['plan_mode']['renders EnterPlanMode tool'] = function()
  helpers.replay_streaming(_G.child, 'plan_mode')
  assert_any_line_matches(_G.child, '^%s+%S+%s+EnterPlanMode:')
end

-- ---------------------------------------------------------------------------
-- Fold levels in streaming path
-- ---------------------------------------------------------------------------
T['streaming_folds'] = MiniTest.new_set()

T['streaming_folds']['agent header has fold level >1'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  local levels = helpers.get_fold_levels(_G.child)
  local found = false
  for _, fl in pairs(levels) do
    if fl == '>1' then found = true; break end
  end
  eq(found, true)
end

T['streaming_folds']['tool header has fold level >2'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  local levels = helpers.get_fold_levels(_G.child)
  local found = false
  for _, fl in pairs(levels) do
    if fl == '>2' then found = true; break end
  end
  eq(found, true)
end

T['streaming_folds']['tool result has fold level >3'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  local levels = helpers.get_fold_levels(_G.child)
  local found = false
  for _, fl in pairs(levels) do
    if fl == '>3' then found = true; break end
  end
  eq(found, true)
end

return T
