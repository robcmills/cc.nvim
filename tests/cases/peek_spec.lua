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

--- Redirect HOME + XDG_CACHE_HOME to a tempdir and force cc.peek to re-eval
--- its module-level path constants. Returns the resolved cache root.
local function setup_temp_cache(child)
  return child.lua_get([[(function()
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, 'p')
    vim.env.HOME = home
    vim.env.XDG_CACHE_HOME = home .. '/.cache'
    package.loaded['cc.peek'] = nil
    return require('cc.peek')._cache_root
  end)()]])
end

-- ---------------------------------------------------------------------------
-- strip_wrap
-- ---------------------------------------------------------------------------
T['strip_wrap'] = MiniTest.new_set()

T['strip_wrap']['collapses wrapped command back to original'] = function()
  local cache_root = setup_temp_cache(_G.child)
  local cmd = string.format(
    'set -o pipefail; { yarn install; } 2>&1 | tee %s/sess-abc/toolu_xyz.log', cache_root)
  local out = _G.child.lua_get(string.format(
    [[require('cc.peek').strip_wrap(%q)]], cmd))
  eq(out, 'yarn install')
end

T['strip_wrap']['unwrapped command passes through'] = function()
  setup_temp_cache(_G.child)
  local out = _G.child.lua_get([[require('cc.peek').strip_wrap('echo hello')]])
  eq(out, 'echo hello')
end

T['strip_wrap']['nil/non-string returns empty string'] = function()
  setup_temp_cache(_G.child)
  local out = _G.child.lua_get([[require('cc.peek').strip_wrap(nil)]])
  eq(out, '')
end

T['strip_wrap']['preserves nested braces in original command'] = function()
  local cache_root = setup_temp_cache(_G.child)
  local cmd = string.format(
    'set -o pipefail; { foo && { bar; baz; }; } 2>&1 | tee %s/s/t.log', cache_root)
  local out = _G.child.lua_get(string.format(
    [[require('cc.peek').strip_wrap(%q)]], cmd))
  eq(out, 'foo && { bar; baz; }')
end

-- ---------------------------------------------------------------------------
-- list_running
-- ---------------------------------------------------------------------------
T['list_running'] = MiniTest.new_set()

--- Build a fake instance with a session.id and tool_calls and register it so
--- cc.find_instance(bufnr) returns it. Returns the bufnr.
local function setup_fake_instance(child, session_id, tool_calls)
  return child.lua_get(string.format([[(function()
    local cc = require('cc')
    local Session = require('cc.session')
    local bufnr = vim.api.nvim_create_buf(false, true)
    local sess = Session.new()
    sess.id = %q
    sess.tool_calls = %s
    local fake = {
      session = sess,
      output = { bufnr = bufnr },
    }
    cc.find_instance = function(b) if b == bufnr then return fake end end
    return bufnr
  end)()]], session_id, tool_calls))
end

T['list_running']['returns long-timeout Bash calls without results'] = function()
  local cache_root = setup_temp_cache(_G.child)
  local bufnr = setup_fake_instance(_G.child, 'sess1', [[{
    ['toolu_a'] = {
      name = 'Bash',
      input = { command = 'yarn install', timeout = 60000 },
      result = nil,
      start_time = 1000,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 1)
  eq(out[1].id, 'toolu_a')
  eq(out[1].command, 'yarn install')
  eq(out[1].log_path, cache_root .. '/sess1/toolu_a.log')
end

T['list_running']['filters out non-Bash tools'] = function()
  setup_temp_cache(_G.child)
  local bufnr = setup_fake_instance(_G.child, 'sess1', [[{
    ['toolu_b'] = {
      name = 'Read',
      input = { file_path = '/etc/hosts', timeout = 60000 },
      result = nil,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

T['list_running']['filters out completed calls (with result)'] = function()
  setup_temp_cache(_G.child)
  local bufnr = setup_fake_instance(_G.child, 'sess1', [[{
    ['toolu_done'] = {
      name = 'Bash',
      input = { command = 'ls', timeout = 60000 },
      result = 'output',
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

T['list_running']['filters out short-timeout Bash calls (hook does not wrap)'] = function()
  setup_temp_cache(_G.child)
  local bufnr = setup_fake_instance(_G.child, 'sess1', [[{
    ['toolu_short'] = {
      name = 'Bash',
      input = { command = 'echo hi', timeout = 5000 },
      result = nil,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

T['list_running']['filters out Bash calls with no timeout (hook does not wrap)'] = function()
  setup_temp_cache(_G.child)
  local bufnr = setup_fake_instance(_G.child, 'sess1', [[{
    ['toolu_notimeout'] = {
      name = 'Bash',
      input = { command = 'echo hi' },
      result = nil,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

T['list_running']['rejects unsafe session_id (path traversal)'] = function()
  setup_temp_cache(_G.child)
  -- Session ID with shell/path metacharacters must not produce any candidate
  -- — the log_path would otherwise escape the cache root.
  local bufnr = setup_fake_instance(_G.child, '../etc/passwd', [[{
    ['toolu_x'] = {
      name = 'Bash',
      input = { command = 'ls', timeout = 60000 },
      result = nil,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

T['list_running']['rejects unsafe tool_use_id (path traversal)'] = function()
  setup_temp_cache(_G.child)
  local bufnr = setup_fake_instance(_G.child, 'sess1', [[{
    ['toolu/../../etc'] = {
      name = 'Bash',
      input = { command = 'ls', timeout = 60000 },
      result = nil,
    },
  }]])
  local out = _G.child.lua_get(string.format([[require('cc.peek').list_running(%d)]], bufnr))
  eq(#out, 0)
end

-- ---------------------------------------------------------------------------
-- append_chunk — multi-chunk streaming must not merge across '\n' boundaries.
--
-- Regression: each libuv read_start callback delivers one chunk. When a chunk
-- ends with '\n', the buffer's last line is a completed line and the *next*
-- chunk's first line must start a new line, not concatenate onto it.
-- ---------------------------------------------------------------------------
T['append_chunk'] = MiniTest.new_set()

T['append_chunk']['three newline-terminated chunks produce three lines'] = function()
  setup_temp_cache(_G.child)
  local lines = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    local peek = { bufnr = buf, partial = '' }
    peek_mod._append_chunk(peek, 'a\n')
    peek_mod._append_chunk(peek, 'b\n')
    peek_mod._append_chunk(peek, 'c\n')
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)()]])
  -- Final empty entry is the trailing partial (post-\n).
  eq(lines, { 'a', 'b', 'c', '' })
end

T['append_chunk']['partial line is concatenated until a newline arrives'] = function()
  setup_temp_cache(_G.child)
  local lines = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    local peek = { bufnr = buf, partial = '' }
    peek_mod._append_chunk(peek, 'abc')
    peek_mod._append_chunk(peek, 'def\n')
    peek_mod._append_chunk(peek, 'ghi\n')
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)()]])
  eq(lines, { 'abcdef', 'ghi', '' })
end

T['append_chunk']['user-reported scenario: subsequent chunks do not merge onto previous'] = function()
  setup_temp_cache(_G.child)
  -- Reproduces the exact bug: chunk1 carries "echo 1..echo 4\n", then each
  -- per-line chunk that follows must land on its own line — not get smashed
  -- onto "echo 4" as "echo 4echo 5echo 6echo 7".
  local lines = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    local peek = { bufnr = buf, partial = '' }
    peek_mod._append_chunk(peek, 'echo 1\necho 2\necho 3\necho 4\n')
    peek_mod._append_chunk(peek, 'echo 5\n')
    peek_mod._append_chunk(peek, 'echo 6\n')
    peek_mod._append_chunk(peek, 'echo 7\n')
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)()]])
  eq(lines, { 'echo 1', 'echo 2', 'echo 3', 'echo 4', 'echo 5', 'echo 6', 'echo 7', '' })
end

T['append_chunk']['multi-line chunk ending without newline preserves partial'] = function()
  setup_temp_cache(_G.child)
  local result = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    local peek = { bufnr = buf, partial = '' }
    peek_mod._append_chunk(peek, 'a\nb\nc')
    peek_mod._append_chunk(peek, 'd\n')
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      partial = peek.partial,
    }
  end)()]])
  eq(result.lines, { 'a', 'b', 'cd', '' })
  eq(result.partial, '')
end

T['append_chunk']['empty chunk is a no-op'] = function()
  setup_temp_cache(_G.child)
  local result = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    local peek = { bufnr = buf, partial = '' }
    peek_mod._append_chunk(peek, 'hello\n')
    peek_mod._append_chunk(peek, '')
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      partial = peek.partial,
    }
  end)()]])
  eq(result.lines, { 'hello', '' })
  eq(result.partial, '')
end

-- ---------------------------------------------------------------------------
-- placeholder — shown when peek opens on an empty/missing log, cleared on
-- the first real chunk so streamed content takes its place cleanly.
-- ---------------------------------------------------------------------------
T['placeholder'] = MiniTest.new_set()

T['placeholder']['set populates buffer with the canned waiting message'] = function()
  setup_temp_cache(_G.child)
  local lines = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false
    local peek = { bufnr = buf, partial = '', placeholder = false }
    peek_mod._set_placeholder(peek)
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      placeholder = peek.placeholder,
    }
  end)()]])
  eq(lines.placeholder, true)
  eq(lines.lines, _G.child.lua_get([[require('cc.peek')._PLACEHOLDER_LINES]]))
end

T['placeholder']['clear wipes buffer and resets partial state'] = function()
  setup_temp_cache(_G.child)
  local result = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    local peek = { bufnr = buf, partial = 'leftover', placeholder = false }
    peek_mod._set_placeholder(peek)
    peek_mod._clear_placeholder(peek)
    return {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      placeholder = peek.placeholder,
      partial = peek.partial,
    }
  end)()]])
  eq(result.lines, { '' })
  eq(result.placeholder, false)
  eq(result.partial, '')
end

T['placeholder']['append_chunk after clear streams cleanly (no residue)'] = function()
  setup_temp_cache(_G.child)
  local lines = _G.child.lua_get([[(function()
    local peek_mod = require('cc.peek')
    local buf = vim.api.nvim_create_buf(false, true)
    local peek = { bufnr = buf, partial = '', placeholder = false }
    peek_mod._set_placeholder(peek)
    -- Mirror what the schedule callback does on first chunk: clear the
    -- placeholder, then run append_chunk normally.
    peek_mod._clear_placeholder(peek)
    peek_mod._append_chunk(peek, 'first line\nsecond line\n')
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)()]])
  eq(lines, { 'first line', 'second line', '' })
end

-- ---------------------------------------------------------------------------
-- gc
-- ---------------------------------------------------------------------------
T['gc'] = MiniTest.new_set()

T['gc']['removes stale dirs and preserves current session + recent ones'] = function()
  local cache_root = setup_temp_cache(_G.child)
  local result = _G.child.lua_get(string.format([[(function()
    local root = %q
    vim.fn.mkdir(root .. '/test-stale-old', 'p')
    vim.fn.mkdir(root .. '/test-recent-keep', 'p')
    vim.fn.mkdir(root .. '/test-current-session', 'p')
    -- Backdate "stale" two hours ago.
    local stale = root .. '/test-stale-old'
    local two_hr_ago = os.time() - 7200
    vim.fn.system({ 'touch', '-t',
      os.date('%%Y%%m%%d%%H%%M.%%S', two_hr_ago), stale })
    require('cc.peek').gc(os.time(), 'test-current-session')
    local exists = function(p) return vim.fn.isdirectory(p) == 1 end
    return {
      stale_removed = not exists(stale),
      recent_kept = exists(root .. '/test-recent-keep'),
      current_kept = exists(root .. '/test-current-session'),
    }
  end)()]], cache_root))
  eq(result.stale_removed, true)
  eq(result.recent_kept, true)
  eq(result.current_kept, true)
end

T['gc']['safe to run when cache root does not exist'] = function()
  setup_temp_cache(_G.child)
  -- cache root has not been created yet — gc must not raise.
  _G.child.lua([[require('cc.peek').gc(os.time(), 'whatever')]])
end

-- ---------------------------------------------------------------------------
-- Hook script — run as a real subprocess.
-- ---------------------------------------------------------------------------
T['hook_script'] = MiniTest.new_set()

local function run_hook(child, payload_table, env)
  local script = helpers.repo_root .. '/hooks/cc-peek-wrap.sh'
  local payload = vim.json.encode(payload_table)
  return child.lua_get(string.format([[(function()
    local payload = %q
    local env = %s
    local cmd = { 'env' }
    for k, v in pairs(env) do table.insert(cmd, k .. '=' .. v) end
    table.insert(cmd, %q)
    local out = vim.fn.system(cmd, payload)
    return { out = out, code = vim.v.shell_error }
  end)()]], payload, vim.inspect(env or {}), script))
end

T['hook_script']['wraps long-timeout Bash with tee under cache root'] = function()
  local cache_root = setup_temp_cache(_G.child)
  local r = run_hook(_G.child, {
    tool_name = 'Bash',
    session_id = 'sess-test-1',
    tool_use_id = 'toolu_test_1',
    tool_input = { command = 'sleep 1', timeout = 60000 },
  }, { XDG_CACHE_HOME = vim.fn.fnamemodify(cache_root, ':h') })
  eq(r.code, 0)
  local expected = string.format('tee %s/sess%%-test%%-1/toolu_test_1%%.log', vim.pesc(cache_root))
  if not r.out:find(expected) then
    error('expected tee path in output: ' .. r.out:sub(1, 400))
  end
  if not r.out:find('hookSpecificOutput') then
    error('expected hookSpecificOutput key in: ' .. r.out:sub(1, 400))
  end
end

T['hook_script']['short-timeout Bash passes through (empty output, exit 0)'] = function()
  local r = run_hook(_G.child, {
    tool_name = 'Bash',
    session_id = 'sess-test-2',
    tool_use_id = 'toolu_short',
    tool_input = { command = 'ls', timeout = 5000 },
  })
  eq(r.code, 0)
  eq(r.out:gsub('%s', ''), '')
end

T['hook_script']['Bash without timeout passes through'] = function()
  local r = run_hook(_G.child, {
    tool_name = 'Bash',
    session_id = 'sess-test-3',
    tool_use_id = 'toolu_no_timeout',
    tool_input = { command = 'echo hi' },
  })
  eq(r.code, 0)
  eq(r.out:gsub('%s', ''), '')
end

T['hook_script']['non-Bash tool passes through'] = function()
  local r = run_hook(_G.child, {
    tool_name = 'Read',
    session_id = 'sess-test-4',
    tool_use_id = 'toolu_read',
    tool_input = { file_path = '/etc/hosts' },
  })
  eq(r.code, 0)
  eq(r.out:gsub('%s', ''), '')
end

T['hook_script']['rejects unsafe session_id (path traversal)'] = function()
  local r = run_hook(_G.child, {
    tool_name = 'Bash',
    session_id = '../etc/passwd',
    tool_use_id = 'toolu_x',
    tool_input = { command = 'ls', timeout = 60000 },
  })
  -- Pass-through (no wrap) is the safe outcome here.
  eq(r.code, 0)
  eq(r.out:gsub('%s', ''), '')
end

T['hook_script']['rejects unsafe tool_use_id (shell metachars)'] = function()
  local r = run_hook(_G.child, {
    tool_name = 'Bash',
    session_id = 'sess-clean',
    tool_use_id = 'toolu$(rm -rf x)',
    tool_input = { command = 'ls', timeout = 60000 },
  })
  eq(r.code, 0)
  eq(r.out:gsub('%s', ''), '')
end

T['hook_script']['cache dir created with 0700 perms (umask 077)'] = function()
  local cache_root = setup_temp_cache(_G.child)
  local xdg = vim.fn.fnamemodify(cache_root, ':h')
  local r = run_hook(_G.child, {
    tool_name = 'Bash',
    session_id = 'sess-perm',
    tool_use_id = 'toolu_perm',
    tool_input = { command = 'true', timeout = 60000 },
  }, { XDG_CACHE_HOME = xdg })
  eq(r.code, 0)
  local mode = _G.child.lua_get(string.format(
    [[vim.fn.getfperm(%q)]], cache_root .. '/sess-perm'))
  eq(mode, 'rwx------')
end

return T
