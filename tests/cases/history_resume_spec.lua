-- Tests for history resume path — render_historical_record, transcript reading,
-- truncation, and resume notice rendering.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

--- Assert that a pattern appears somewhere in the buffer.
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
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

-- ---------------------------------------------------------------------------
-- read_transcript
-- ---------------------------------------------------------------------------
T['read_transcript'] = MiniTest.new_set()

T['read_transcript']['returns user_text records'] = function()
  local records = helpers.load_fixture_records(_G.child, 'simple_text')
  local found = false
  for _, r in ipairs(records) do
    if r.type == 'user_text' then found = true; break end
  end
  eq(found, true)
end

T['read_transcript']['returns assistant records'] = function()
  local records = helpers.load_fixture_records(_G.child, 'simple_text')
  local found = false
  for _, r in ipairs(records) do
    if r.type == 'assistant' then found = true; break end
  end
  eq(found, true)
end

T['read_transcript']['returns user_tool_result records'] = function()
  local records = helpers.load_fixture_records(_G.child, 'tool_bash')
  local found = false
  for _, r in ipairs(records) do
    if r.type == 'user_tool_result' then found = true; break end
  end
  eq(found, true)
end

T['read_transcript']['multi_turn produces multiple records'] = function()
  local records = helpers.load_fixture_records(_G.child, 'multi_turn')
  eq(#records >= 3, true)
end

-- ---------------------------------------------------------------------------
-- render_historical_record
-- ---------------------------------------------------------------------------
T['render_historical'] = MiniTest.new_set()

T['render_historical']['renders user text'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  assert_buffer_contains(_G.child, 'apple banana cherry')
end

T['render_historical']['renders assistant text'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  assert_any_line_matches(_G.child, 'Agent:')
end

T['render_historical']['renders tool_use blocks'] = function()
  helpers.render_fixture(_G.child, 'tool_bash')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Bash:')
end

T['render_historical']['renders tool_result blocks'] = function()
  helpers.render_fixture(_G.child, 'tool_bash')
  assert_any_line_matches(_G.child, 'Output:')
end

T['render_historical']['multiple fixtures render without error'] = function()
  -- Render several fixtures sequentially into the same buffer
  -- to simulate a resume that replays many records
  _G.child.lua([==[
    local history = require('cc.history')
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local fixtures = { 'simple_text', 'tool_bash', 'tool_read', 'tool_edit' }
    for _, name in ipairs(fixtures) do
      local path = ']==] .. helpers.fixtures_dir .. [==[/' .. name .. '.jsonl'
      local records = history.read_transcript(path)
      for _, rec in ipairs(records) do
        output:render_historical_record(rec)
      end
    end
    _G._test_bufnr = bufnr
  ]==])
  local lines = helpers.get_buffer_lines(_G.child)
  -- Should have content from multiple fixtures
  eq(#lines > 10, true)
end

-- ---------------------------------------------------------------------------
-- Resume notice
-- ---------------------------------------------------------------------------
T['resume_notice'] = MiniTest.new_set()

T['resume_notice']['render_notice adds a delineator line'] = function()
  _G.child.lua([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    output:ensure_buffer()
    vim.api.nvim_set_current_buf(output.bufnr)
    output:render_notice('resumed abc12345')
    _G._test_bufnr = output.bufnr
  ]==])
  assert_any_line_matches(_G.child, 'resumed abc12345')
end

T['resume_notice']['truncation notice renders for large transcripts'] = function()
  -- Simulate what cc.resume() does when records > max
  _G.child.lua([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({ history_max_records = 2 })
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    output:ensure_buffer()
    vim.api.nvim_set_current_buf(output.bufnr)

    -- Simulate 5 records, max = 2, so first 3 are skipped
    local total_records = 5
    local max = 2
    local start_idx = total_records - max + 1  -- = 4
    output:render_notice(string.format(
      'earlier history hidden (%d records); showing last %d', start_idx - 1, max))
    _G._test_bufnr = output.bufnr
  ]==])
  assert_any_line_matches(_G.child, 'earlier history hidden')
  assert_any_line_matches(_G.child, '3 records')
end

-- ---------------------------------------------------------------------------
-- Fold structure preserved across resume
-- ---------------------------------------------------------------------------
T['resume_folds'] = MiniTest.new_set()

T['resume_folds']['fold levels match expected structure'] = function()
  helpers.render_fixture(_G.child, 'tool_bash')
  local levels = helpers.get_fold_levels(_G.child)
  -- Should have >1 (turn header), >2 (tool header), >3 (output header)
  local has_gt1, has_gt2, has_gt3 = false, false, false
  for _, fl in pairs(levels) do
    if fl == '>1' then has_gt1 = true end
    if fl == '>2' then has_gt2 = true end
    if fl == '>3' then has_gt3 = true end
  end
  eq(has_gt1, true)
  eq(has_gt2, true)
  eq(has_gt3, true)
end

T['resume_folds']['highlights applied on resumed content'] = function()
  helpers.render_fixture(_G.child, 'tool_bash')
  local lines = helpers.get_buffer_lines(_G.child)
  -- Find the Agent: line and check it has a syntax highlight
  for i, line in ipairs(lines) do
    if line:match('^%s*Agent:') then
      local stack = helpers.get_syn_stack(_G.child, i, line:find('A'))
      -- Should have CcAgent in the syntax stack
      local found = false
      for _, name in ipairs(stack) do
        if name == 'CcAgent' then found = true; break end
      end
      eq(found, true)
      return
    end
  end
  error('No Agent: line found')
end

return T
