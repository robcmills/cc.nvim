-- Tests for cc.peek — list_running, strip_wrap, gc, and hook script behavior.
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
-- strip_wrap
-- ---------------------------------------------------------------------------
T['strip_wrap'] = MiniTest.new_set()

T['strip_wrap']['collapses wrapped command back to original'] = function()
  local out = _G.child.lua_get([[
    require('cc.peek').strip_wrap(
      'set -o pipefail; { yarn install; } 2>&1 | tee /tmp/cc-peek/sess-abc/toolu_xyz.log')
  ]])
  eq(out, 'yarn install')
end

T['strip_wrap']['unwrapped command passes through'] = function()
  local out = _G.child.lua_get([[require('cc.peek').strip_wrap('echo hello')]])
  eq(out, 'echo hello')
end

T['strip_wrap']['nil/non-string returns empty string'] = function()
  local out = _G.child.lua_get([[require('cc.peek').strip_wrap(nil)]])
  eq(out, '')
end

T['strip_wrap']['preserves nested braces in original command'] = function()
  local out = _G.child.lua_get([[
    require('cc.peek').strip_wrap(
      'set -o pipefail; { foo && { bar; baz; }; } 2>&1 | tee /tmp/cc-peek/s/t.log')
  ]])
  eq(out, 'foo && { bar; baz; }')
end

-- ---------------------------------------------------------------------------
-- list_running
-- ---------------------------------------------------------------------------
T['list_running'] = MiniTest.new_set()

--- Build a fake instance with a session containing tool_calls and register
--- it so cc.find_instance(bufnr) returns it. Returns the bufnr.
local function setup_fake_instance(child, tool_calls)
  return child.lua_get(string.format([[(function()
    local cc = require('cc')
    local Session = require('cc.session')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local sess = Session.new()
    sess.tool_calls = %s
    local fake = {
      session = sess,
      output = { bufnr = bufnr },
    }
    -- Inject a fake into the find_instance path. cc.find_instance walks the
    -- module-private instances table, so we override it for the test.
    cc.find_instance = function(b) if b == bufnr then return fake end end
    return bufnr
  end)()]], tool_calls))
end

T['list_running']['returns wrapped Bash calls without results'] = function()
  local bufnr = setup_fake_instance(_G.child, [[{
    ['toolu_a'] = {
      name = 'Bash',
      input = { command = 'set -o pipefail; { yarn install; } 2>&1 | tee /tmp/cc-peek/sess1/toolu_a.log' },
      result = nil,
      start_time = 1000,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 1)
  eq(out[1].id, 'toolu_a')
  eq(out[1].command, 'yarn install')
  eq(out[1].log_path, '/tmp/cc-peek/sess1/toolu_a.log')
end

T['list_running']['filters out non-Bash tools'] = function()
  local bufnr = setup_fake_instance(_G.child, [[{
    ['toolu_b'] = {
      name = 'Read',
      input = { command = 'set -o pipefail; { cat foo; } 2>&1 | tee /tmp/cc-peek/s/t.log' },
      result = nil,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

T['list_running']['filters out completed calls (with result)'] = function()
  local bufnr = setup_fake_instance(_G.child, [[{
    ['toolu_done'] = {
      name = 'Bash',
      input = { command = 'set -o pipefail; { ls; } 2>&1 | tee /tmp/cc-peek/s/t.log' },
      result = 'output',
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

T['list_running']['filters out unwrapped Bash calls'] = function()
  local bufnr = setup_fake_instance(_G.child, [[{
    ['toolu_short'] = {
      name = 'Bash',
      input = { command = 'echo hi' },
      result = nil,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

-- ---------------------------------------------------------------------------
-- gc
-- ---------------------------------------------------------------------------
T['gc'] = MiniTest.new_set()

T['gc']['removes stale dirs and preserves current session + recent ones'] = function()
  local result = _G.child.lua_get([[(function()
    local root = '/tmp/cc-peek-test-' .. os.time() .. '-' .. math.random(10000)
    -- Replace the LOG_ROOT just for this test by monkey-patching gc.
    -- Easier: drop dirs into the actual root and clean up after.
    local real_root = '/tmp/cc-peek'
    vim.fn.mkdir(real_root .. '/test-stale-old', 'p')
    vim.fn.mkdir(real_root .. '/test-recent-keep', 'p')
    vim.fn.mkdir(real_root .. '/test-current-session', 'p')
    -- Backdate "stale" two hours ago.
    local stale = real_root .. '/test-stale-old'
    local two_hr_ago = os.time() - 7200
    vim.fn.system({ 'touch', '-t',
      os.date('%Y%m%d%H%M.%S', two_hr_ago), stale })
    require('cc.peek').gc(os.time(), 'test-current-session')
    local exists = function(p) return vim.fn.isdirectory(p) == 1 end
    local r = {
      stale_removed = not exists(stale),
      recent_kept = exists(real_root .. '/test-recent-keep'),
      current_kept = exists(real_root .. '/test-current-session'),
    }
    -- Clean up
    pcall(vim.fn.delete, real_root .. '/test-recent-keep', 'rf')
    pcall(vim.fn.delete, real_root .. '/test-current-session', 'rf')
    pcall(vim.fn.delete, real_root .. '/test-stale-old', 'rf')
    return r
  end)()]])
  eq(result.stale_removed, true)
  eq(result.recent_kept, true)
  eq(result.current_kept, true)
end

-- ---------------------------------------------------------------------------
-- Hook script — run as a real subprocess.
-- ---------------------------------------------------------------------------
T['hook_script'] = MiniTest.new_set()

local function run_hook(payload_table)
  local script = helpers.repo_root .. '/hooks/cc-peek-wrap.sh'
  local payload = vim.json.encode(payload_table)
  local out = vim.fn.system({ script }, payload)
  return out, vim.v.shell_error
end

T['hook_script']['wraps long-timeout Bash and emits hookSpecificOutput'] = function()
  local out, code = run_hook({
    tool_name = 'Bash',
    session_id = 'sess-test-1',
    tool_use_id = 'toolu_test_1',
    tool_input = { command = 'sleep 1', timeout = 60000 },
  })
  eq(code, 0)
  if not out:find('tee /tmp/cc%-peek/sess%-test%-1/toolu_test_1%.log') then
    error('expected tee path in output: ' .. out:sub(1, 400))
  end
  if not out:find('hookSpecificOutput') then
    error('expected hookSpecificOutput key in: ' .. out:sub(1, 400))
  end
  pcall(vim.fn.delete, '/tmp/cc-peek/sess-test-1', 'rf')
end

T['hook_script']['short-timeout Bash passes through (empty output, exit 0)'] = function()
  local out, code = run_hook({
    tool_name = 'Bash',
    session_id = 'sess-test-2',
    tool_use_id = 'toolu_short',
    tool_input = { command = 'ls', timeout = 5000 },
  })
  eq(code, 0)
  eq(out:gsub('%s', ''), '')
end

T['hook_script']['Bash without timeout passes through'] = function()
  local out, code = run_hook({
    tool_name = 'Bash',
    session_id = 'sess-test-3',
    tool_use_id = 'toolu_no_timeout',
    tool_input = { command = 'echo hi' },
  })
  eq(code, 0)
  eq(out:gsub('%s', ''), '')
end

T['hook_script']['non-Bash tool passes through'] = function()
  local out, code = run_hook({
    tool_name = 'Read',
    session_id = 'sess-test-4',
    tool_use_id = 'toolu_read',
    tool_input = { file_path = '/etc/hosts' },
  })
  eq(code, 0)
  eq(out:gsub('%s', ''), '')
end

T['hook_script']['rejects unsafe session_id'] = function()
  local out, code = run_hook({
    tool_name = 'Bash',
    session_id = '../etc/passwd',
    tool_use_id = 'toolu_x',
    tool_input = { command = 'ls', timeout = 60000 },
  })
  -- Pass-through (no wrap) is the safe outcome here.
  eq(code, 0)
  eq(out:gsub('%s', ''), '')
end

return T
