-- Process-level integration tests: spawn fake_claude.sh as the command,
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
      cmd = %q,
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
    vim.wait(5000, function() return process_exited end, 10)
    -- Drain any remaining scheduled callbacks
    vim.wait(50, function() return false end)

    _G._test_bufnr = bufnr
    _G._test_output = output
    _G._test_session = session
    _G._test_process_exited = process_exited
  ]==], fixture_path, FAKE_CLAUDE))
end

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

-- ---------------------------------------------------------------------------
-- Basic pipeline: fake_claude -> process -> parser -> router -> output
-- ---------------------------------------------------------------------------
T['pipeline'] = MiniTest.new_set()

-- A single end-to-end check: spawn fake_claude with multi_block (covers text
-- streaming, multiple tools, and final result.usage), assert that the process
-- exited cleanly and that text, tool headers, and session state all made it
-- through the full process.lua → parser → router → output → session path.
-- Granular rendering assertions (per-tool, per-message-type) live in
-- streaming_spec via the same router/output, but without the subprocess.
T['pipeline']['multi_block exercises the full subprocess pipeline'] = function()
  spawn_with_fixture(_G.child, 'multi_block')
  eq(_G.child.lua_get('_G._test_process_exited'), true)
  assert_any_line_matches(_G.child, 'Agent:')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Read:')
  assert_any_line_matches(_G.child, '^%s+%S+%s+Bash:')
  assert_buffer_contains(_G.child, 'All done')
  local state = helpers.get_session_state(_G.child)
  eq(type(state.id), 'string')
  eq(type(state.model), 'string')
end

T['pipeline']['hook events render through process pipe'] = function()
  spawn_with_fixture(_G.child, 'hook_events')
  assert_any_line_matches(_G.child, 'Hook:.*PreToolUse')
  assert_any_line_matches(_G.child, 'Hook:.*PostToolUse')
end

return T
