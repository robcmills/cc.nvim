-- Process-level integration tests: spawn fake_claude.sh as the claude_cmd,
-- exercise the full pipeline: process.lua -> parser -> router -> output.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local FAKE_CLAUDE = helpers.repo_root .. '/tests/fixtures/fake_claude.sh'

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

--- Spawn fake_claude.sh with a fixture, wait for output, store buffer.
--- This exercises the full pipeline: process.lua -> parser -> router -> output.
---@param child table mini.test child
---@param fixture_name string
local function spawn_with_fixture(child, fixture_name)
  local fixture_path = helpers.ndjson_fixtures_dir .. '/' .. fixture_name .. '.ndjson'
  child.lua(string.format([==[
    local Process = require('cc.process')
    local Parser = require('cc.parser')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({})

    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local router = Router.new({ session = session, output = output })

    -- Set env var for fake_claude.sh
    vim.env.CC_TEST_FIXTURE = %q

    local process_exited = false
    local process = Process.new({
      claude_cmd = %q,
      cwd = vim.fn.getcwd(),
      on_message = function(msg)
        router:dispatch(msg)
      end,
      on_exit = function(code, signal)
        process_exited = true
      end,
    })
    router:set_process(process)
    process:spawn()

    -- Wait for subprocess to exit (max 5s)
    vim.wait(5000, function() return process_exited end, 50)
    -- Drain any remaining scheduled callbacks
    vim.wait(200, function() return false end)

    _G._test_bufnr = bufnr
    _G._test_output = output
    _G._test_session = session
    _G._test_process_exited = process_exited
  ]==], fixture_path, FAKE_CLAUDE))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

-- ---------------------------------------------------------------------------
-- Basic pipeline: fake_claude -> process -> parser -> router -> output
-- ---------------------------------------------------------------------------
T['pipeline'] = MiniTest.new_set()

T['pipeline']['process exits cleanly'] = function()
  spawn_with_fixture(_G.child, 'simple_text')
  local exited = _G.child.lua_get('_G._test_process_exited')
  eq(exited, true)
end

T['pipeline']['simple_text renders agent turn'] = function()
  spawn_with_fixture(_G.child, 'simple_text')
  assert_any_line_matches(_G.child, 'Agent:')
end

T['pipeline']['simple_text renders streamed text'] = function()
  spawn_with_fixture(_G.child, 'simple_text')
  assert_buffer_contains(_G.child, 'Hello world!')
end

T['pipeline']['simple_text renders cost'] = function()
  spawn_with_fixture(_G.child, 'simple_text')
  assert_any_line_matches(_G.child, '%$0%.0012')
end

T['pipeline']['tool_bash renders tool and result'] = function()
  spawn_with_fixture(_G.child, 'tool_bash')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Bash:')
  assert_buffer_contains(_G.child, 'file1%.txt')
end

T['pipeline']['session state populated through process pipe'] = function()
  spawn_with_fixture(_G.child, 'simple_text')
  local state = helpers.get_session_state(_G.child)
  eq(state.id, 'test-stream-001')
  eq(state.model, 'claude-sonnet-4-20250514')
  eq(state.cost_usd, 0.0012)
end

T['pipeline']['multi_block renders multiple tools and text'] = function()
  spawn_with_fixture(_G.child, 'multi_block')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Read:')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Bash:')
  assert_buffer_contains(_G.child, 'All done')
end

T['pipeline']['hook events render through process pipe'] = function()
  spawn_with_fixture(_G.child, 'hook_events')
  assert_any_line_matches(_G.child, 'Hook:.*PreToolUse')
  assert_any_line_matches(_G.child, 'Hook:.*PostToolUse')
end

return T
