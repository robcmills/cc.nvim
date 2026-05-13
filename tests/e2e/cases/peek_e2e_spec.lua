-- E2E test for :CcPeek streaming/preload behavior.
--
-- Drives a real child nvim with an NDJSON fixture that emits three
-- long-timeout Bash tool_use blocks (and no tool_results), so all three
-- end up "running" in session.tool_calls when :CcPeek is invoked.
--
-- Per-tool log files under $XDG_CACHE_HOME/cc-peek/<session>/<id>.log
-- are pre-staged by this test (mirroring what hooks/cc-peek-wrap.sh would
-- write at runtime). We then exercise both code paths the user hit:
--   - log file already populated when peek opens (preload should show it)
--   - log file empty/missing when peek opens, then bytes appended later
--     (streaming should pick them up via tail -F)

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local uv = vim.uv or vim.loop

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      _G.child = nil
      _G.tmp_xdg = nil
    end,
    post_case = function()
      if _G.child then pcall(function() _G.child:close() end); _G.child = nil end
      if _G.tmp_xdg then pcall(vim.fn.delete, _G.tmp_xdg, 'rf'); _G.tmp_xdg = nil end
    end,
  },
})

local SESSION_ID = 'peek-test-session'
local IDS = { 'toolu_peek001', 'toolu_peek002', 'toolu_peek003' }

--- Create a unique temp dir, populate $XDG_CACHE_HOME/cc-peek/<session>/.
--- Returns { xdg, cache_root, session_dir, log_paths }.
local function stage_cache()
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, 'p')
  local cache_root = tmp .. '/cc-peek'
  local session_dir = cache_root .. '/' .. SESSION_ID
  vim.fn.mkdir(session_dir, 'p')
  local log_paths = {}
  for _, id in ipairs(IDS) do
    log_paths[id] = session_dir .. '/' .. id .. '.log'
  end
  return {
    xdg = tmp,
    cache_root = cache_root,
    session_dir = session_dir,
    log_paths = log_paths,
  }
end

--- Append a chunk to a log file (mirrors what `tee` would do for new
--- bytes from the wrapped bash subprocess). Uses append mode so we don't
--- truncate.
local function append_log(path, text)
  local f = io.open(path, 'a')
  assert(f, 'failed to open log: ' .. path)
  f:write(text)
  f:close()
end

--- Drive child nvim with the peek_three_bash fixture and wait until
--- list_running reports exactly 3 candidates (i.e. all three tool_use
--- blocks have finalized through router.dispatch).
local function open_session_with_three_tools(child)
  h.open_with_fixture(child, 'peek_three_bash')
  if not child:wait_for(function(c) return c:find_winid_for_buf('cc-nvim-output') ~= nil end, 3000) then
    error('cc-nvim-output never appeared')
  end
  local ok = child:wait_for(function(c)
    return c:lua([[
      local cc = require('cc')
      local buf = vim.fn.bufnr('cc-nvim-output')
      if buf <= 0 then return false end
      local inst = cc.find_instance(buf)
      if not inst or not inst.session or not inst.session.tool_calls then return false end
      local n = 0
      for _, rec in pairs(inst.session.tool_calls) do
        if type(rec.input) == 'table' and type(rec.input.timeout) == 'number' then
          n = n + 1
        end
      end
      return n == 3
    ]])
  end, 5000)
  if not ok then error('three tool_calls never finalized in session') end
end

-- ---------------------------------------------------------------------------
-- Preload — peek must show the log file's content when a file already exists.
-- ---------------------------------------------------------------------------
T['preload_shows_existing_log_content'] = function()
  local stage = stage_cache()
  _G.tmp_xdg = stage.xdg

  -- Pre-stage log content. log002 is left empty on purpose (the bug-reported
  -- "still empty" case mirrored here).
  append_log(stage.log_paths.toolu_peek001, 'line A1\nline A2\nline A3\n')
  append_log(stage.log_paths.toolu_peek003, 'just one line for cmd3\n')

  _G.child = h.spawn({
    config = 'minimal',
    lines = 40,
    columns = 120,
    env = { XDG_CACHE_HOME = stage.xdg, HOME = stage.xdg },
  })
  open_session_with_three_tools(_G.child)

  -- Open peek floats for each candidate via the module API (skips vim.ui.select).
  _G.child:lua([[
    local peek = require('cc.peek')
    local buf = vim.fn.bufnr('cc-nvim-output')
    local cands = peek.list_running(buf)
    for _, c in ipairs(cands) do peek.open(buf, c) end
  ]])

  -- The peek buffers are populated asynchronously by `tail -c +1 -F`'s first
  -- chunk, which usually lands within a few ms. Poll until each non-empty
  -- file shows up in its buffer (and confirm log002's buffer stays empty).
  local ok = _G.child:wait_for(function(c)
    return c:lua([[
      local peek = require('cc.peek')
      local function get(id)
        local pw = peek._open_peeks[id]
        if not pw then return nil end
        return vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
      end
      local l1 = get('toolu_peek001')
      local l3 = get('toolu_peek003')
      if not l1 or not l3 then return false end
      local function has(lines, target)
        for _, l in ipairs(lines) do
          if type(l) == 'string' and l:find(target, 1, true) then return true end
        end
        return false
      end
      return has(l1, 'line A3') and has(l3, 'just one line for cmd3')
    ]])
  end, 3000)
  if not ok then
    local snap = _G.child:lua([[
      local peek = require('cc.peek')
      local out = {}
      for id, pw in pairs(peek._open_peeks) do
        out[id] = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
      end
      return out
    ]])
    error('preload never arrived: ' .. vim.inspect(snap))
  end

  -- Sanity-check: all three are tracked and each has a live `tail` subprocess.
  local meta = _G.child:lua([[
    local peek = require('cc.peek')
    local out = {}
    for id, pw in pairs(peek._open_peeks) do
      out[id] = { has_tail = pw.tail_handle ~= nil }
    end
    return out
  ]])
  eq(meta.toolu_peek001.has_tail, true)
  eq(meta.toolu_peek002.has_tail, true)
  eq(meta.toolu_peek003.has_tail, true)
end

-- ---------------------------------------------------------------------------
-- Streaming — bytes appended after the float opens must reach the buffer.
-- ---------------------------------------------------------------------------
T['streaming_picks_up_appended_lines'] = function()
  local stage = stage_cache()
  _G.tmp_xdg = stage.xdg

  -- Start log001 with one preloaded line so we can confirm preload+stream coexist.
  append_log(stage.log_paths.toolu_peek001, 'preloaded\n')
  -- log002 starts empty (mirrors the race: peek opens before hook has written).
  -- log003 starts empty.

  _G.child = h.spawn({
    config = 'minimal',
    lines = 40,
    columns = 120,
    env = { XDG_CACHE_HOME = stage.xdg, HOME = stage.xdg },
  })
  open_session_with_three_tools(_G.child)

  -- Open peek floats for all three.
  _G.child:lua([[
    local peek = require('cc.peek')
    local buf = vim.fn.bufnr('cc-nvim-output')
    local cands = peek.list_running(buf)
    for _, c in ipairs(cands) do peek.open(buf, c) end
  ]])

  -- Append new bytes to each log AFTER the floats are open. `tail -F` should
  -- pick these up and the read_start callback should append them to the
  -- corresponding peek buffer.
  for i, id in ipairs(IDS) do
    append_log(stage.log_paths[id], string.format('streamed-%d-line-1\n', i))
    append_log(stage.log_paths[id], string.format('streamed-%d-line-2\n', i))
  end

  -- Poll until all three buffers show the appended content (or fail with a
  -- detailed snapshot). 3s gives tail -F plenty of time even with kqueue
  -- polling on macOS.
  local ok = _G.child:wait_for(function(c)
    return c:lua([[
      local peek = require('cc.peek')
      local function has(line, target)
        return type(line) == 'string' and line:find(target, 1, true) ~= nil
      end
      for id, pw in pairs(peek._open_peeks) do
        local lines = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
        local found_1, found_2 = false, false
        for _, l in ipairs(lines) do
          if has(l, 'streamed-') and has(l, '-line-1') then found_1 = true end
          if has(l, 'streamed-') and has(l, '-line-2') then found_2 = true end
        end
        if not (found_1 and found_2) then return false end
      end
      return true
    ]])
  end, 4000)

  if not ok then
    -- Dump the current state so the failure message is informative.
    local snapshot = _G.child:lua([[
      local peek = require('cc.peek')
      local out = {}
      for id, pw in pairs(peek._open_peeks) do
        out[id] = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
      end
      return out
    ]])
    error('streaming never arrived. buffers: ' .. vim.inspect(snapshot))
  end
end

-- ---------------------------------------------------------------------------
-- Realistic streaming — same path as production:
-- a real `bash -c '{ generator; } | tee LOG'` runs in the background while
-- peek floats are open. This is the *exact* shape the hook installs, so it
-- catches anything the simple io.open append above misses (tee's O_TRUNC
-- open, the producer running in a separate process from the peek host, etc.).
-- ---------------------------------------------------------------------------
T['streaming_with_real_tee_subprocess'] = function()
  local stage = stage_cache()
  _G.tmp_xdg = stage.xdg

  _G.child = h.spawn({
    config = 'minimal',
    lines = 40,
    columns = 120,
    env = { XDG_CACHE_HOME = stage.xdg, HOME = stage.xdg },
  })
  open_session_with_three_tools(_G.child)

  -- Spawn three real wrapped-bash producers. Each prints `tee-N-tick-K`
  -- once per 100ms for 1s, piped to its log file via tee — *the same shape*
  -- the hook installs in production. These run in the *parent* test, not
  -- the child, so the child only sees the on-disk effects via tail -F.
  local producers = {}
  for i, id in ipairs(IDS) do
    local inner = string.format(
      'for k in 1 2 3 4 5 6 7 8 9 10; do printf "tee-%d-tick-%%d\\n" $k; sleep 0.1; done',
      i
    )
    local wrapped = string.format(
      'set -o pipefail; { %s; } 2>&1 | tee %s',
      inner,
      vim.fn.shellescape(stage.log_paths[id])
    )
    local pid = vim.fn.jobstart({ 'bash', '-c', wrapped }, { detach = false })
    table.insert(producers, pid)
  end

  -- Give tee a moment to create+open the files so the *preload* race window
  -- is closed before peek opens. (The whole point of this test is exercising
  -- tail's behavior under real concurrent writes, not the preload empty case
  -- which the prior test already covers.)
  vim.wait(80, function() return false end, nil, true)

  -- Open peek floats for all three while producers are still writing.
  _G.child:lua([[
    local peek = require('cc.peek')
    local buf = vim.fn.bufnr('cc-nvim-output')
    local cands = peek.list_running(buf)
    for _, c in ipairs(cands) do peek.open(buf, c) end
  ]])

  -- Wait for producers to finish so we have a deterministic final state.
  vim.fn.jobwait(producers, 5000)
  -- Drain one more vim.schedule tick so any in-flight read_start callbacks
  -- have a chance to flush into the peek buffers.
  vim.wait(150, function() return false end, nil, true)

  -- Each peek buffer should now contain tick-1 .. tick-10 for its producer.
  -- We accept that tick-1 may have been written before peek opened (preload
  -- catches it); tick-10 is the strict streaming check because it's emitted
  -- last, ~900ms after producer start, well after peek opened.
  local ok = _G.child:wait_for(function(c)
    return c:lua([[
      local peek = require('cc.peek')
      for id, pw in pairs(peek._open_peeks) do
        local lines = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
        local found_last = false
        for _, l in ipairs(lines) do
          if type(l) == 'string' and l:find('tick-10', 1, true) then
            found_last = true; break
          end
        end
        if not found_last then return false end
      end
      return true
    ]])
  end, 4000)

  if not ok then
    local snapshot = _G.child:lua([[
      local peek = require('cc.peek')
      local out = {}
      for id, pw in pairs(peek._open_peeks) do
        out[id] = {
          lines = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false),
          file_size = (vim.uv or vim.loop).fs_stat(peek._open_peeks[id] and
            (vim.api.nvim_buf_get_name(pw.bufnr)) or '') or 'n/a',
        }
      end
      return out
    ]])
    local disk = {}
    for _, id in ipairs(IDS) do
      local f = io.open(stage.log_paths[id], 'r')
      disk[id] = f and f:read('*a') or '<missing>'
      if f then f:close() end
    end
    error(string.format(
      'real-tee streaming never settled.\nbuffer state: %s\non-disk: %s',
      vim.inspect(snapshot), vim.inspect(disk)))
  end
end

-- ---------------------------------------------------------------------------
-- Mirror the production flow most precisely: drive peek from the same RPC
-- channel the user goes through (`:CcPeek` via peek_command), with the
-- vim.ui.select picker stubbed to programmatically choose each candidate.
-- A real tee producer streams to each log so we exercise the *picker* code
-- path on top of the tail/readfile path, in case the bug only shows up
-- through the picker's deferred callback.
-- ---------------------------------------------------------------------------
T['peek_command_via_picker_streams_all_three'] = function()
  local stage = stage_cache()
  _G.tmp_xdg = stage.xdg

  _G.child = h.spawn({
    config = 'minimal',
    lines = 40,
    columns = 120,
    env = { XDG_CACHE_HOME = stage.xdg, HOME = stage.xdg },
  })
  open_session_with_three_tools(_G.child)

  -- Background tee producers, mirroring the hook's wrapped form.
  local producers = {}
  for i, id in ipairs(IDS) do
    local inner = string.format(
      'for k in 1 2 3 4 5 6 7 8 9 10; do printf "P%d-tick-%%d\\n" $k; sleep 0.1; done',
      i
    )
    local wrapped = string.format(
      'set -o pipefail; { %s; } 2>&1 | tee %s',
      inner,
      vim.fn.shellescape(stage.log_paths[id])
    )
    table.insert(producers, vim.fn.jobstart({ 'bash', '-c', wrapped }))
  end

  -- Stub vim.ui.select in the child to auto-pick each candidate in turn,
  -- then call peek.peek_command — exactly what `:CcPeek` does.
  _G.child:lua([[
    local peek = require('cc.peek')
    local picks = { 1, 2, 3 }
    local pick_idx = 0
    vim.ui.select = function(items, _opts, on_choice)
      pick_idx = pick_idx + 1
      local n = picks[pick_idx]
      vim.schedule(function() on_choice(items[n], n) end)
    end
    -- Three invocations to pick each candidate.
    for _ = 1, 3 do
      peek.peek_command()
    end
  ]])

  vim.fn.jobwait(producers, 5000)
  vim.wait(200, function() return false end, nil, true)

  local ok = _G.child:wait_for(function(c)
    return c:lua([[
      local peek = require('cc.peek')
      local n = 0
      for id, pw in pairs(peek._open_peeks) do
        local lines = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
        local found = false
        for _, l in ipairs(lines) do
          if type(l) == 'string' and l:find('tick-10', 1, true) then
            found = true; break
          end
        end
        if not found then return false end
        n = n + 1
      end
      return n == 3
    ]])
  end, 4000)

  if not ok then
    local snapshot = _G.child:lua([[
      local peek = require('cc.peek')
      local out = {}
      for id, pw in pairs(peek._open_peeks) do
        out[id] = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
      end
      return out
    ]])
    error('peek_command via picker failed. buffers: ' .. vim.inspect(snapshot))
  end
end

-- ---------------------------------------------------------------------------
-- End-to-end with the real hook script: feed cc-peek-wrap.sh the same JSON
-- payload claude would, capture its updatedInput.command, run it as a real
-- subprocess that streams via tee into the log file, then verify peek
-- sees both the preload and the live tail.
-- ---------------------------------------------------------------------------
T['end_to_end_via_real_hook_script'] = function()
  local stage = stage_cache()
  _G.tmp_xdg = stage.xdg

  _G.child = h.spawn({
    config = 'minimal',
    lines = 40,
    columns = 120,
    env = { XDG_CACHE_HOME = stage.xdg, HOME = stage.xdg },
  })
  open_session_with_three_tools(_G.child)

  -- For each tool, run the *actual* hook script with a realistic PreToolUse
  -- payload, capture the wrapped command from its hookSpecificOutput, and
  -- exec that wrapped command as a real subprocess. This is byte-identical
  -- to what the SDK does in production.
  local repo_root = h.repo_root
  local hook_script = repo_root .. '/hooks/cc-peek-wrap.sh'

  local producers = {}
  for i, id in ipairs(IDS) do
    local inner = string.format(
      'for k in 1 2 3 4 5 6 7 8 9 10; do printf "real-hook-%d-k%%d\\n" $k; sleep 0.05; done',
      i
    )
    local payload = vim.json.encode({
      tool_name = 'Bash',
      session_id = SESSION_ID,
      tool_use_id = id,
      tool_input = { command = inner, timeout = 60000 },
    })
    local hook_out = vim.fn.system(
      { 'env', 'XDG_CACHE_HOME=' .. stage.xdg, 'HOME=' .. stage.xdg, hook_script },
      payload
    )
    if vim.v.shell_error ~= 0 then
      error('hook script failed: ' .. hook_out)
    end
    local decoded = vim.json.decode(hook_out)
    local wrapped = decoded.hookSpecificOutput.updatedInput.command
    if not wrapped:find('tee') then
      error('hook did not wrap with tee: ' .. wrapped)
    end
    table.insert(producers, vim.fn.jobstart({ 'bash', '-c', wrapped }))
  end

  vim.wait(80, function() return false end, nil, true)

  -- Drive peek_command via stubbed picker (production path).
  _G.child:lua([[
    local peek = require('cc.peek')
    vim.ui.select = function(items, _opts, on_choice)
      local pick = _G._next_pick or 1
      _G._next_pick = pick + 1
      vim.schedule(function() on_choice(items[pick], pick) end)
    end
    _G._next_pick = 1
    for _ = 1, 3 do peek.peek_command() end
  ]])

  vim.fn.jobwait(producers, 5000)
  vim.wait(200, function() return false end, nil, true)

  local ok = _G.child:wait_for(function(c)
    return c:lua([[
      local peek = require('cc.peek')
      local n = 0
      for _, pw in pairs(peek._open_peeks) do
        local lines = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
        local found_first, found_last = false, false
        for _, l in ipairs(lines) do
          if type(l) == 'string' then
            if l:find('k1', 1, true) then found_first = true end
            if l:find('k10', 1, true) then found_last = true end
          end
        end
        if not (found_first and found_last) then return false end
        n = n + 1
      end
      return n == 3
    ]])
  end, 4000)

  if not ok then
    local snapshot = _G.child:lua([[
      local peek = require('cc.peek')
      local out = {}
      for id, pw in pairs(peek._open_peeks) do
        out[id] = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
      end
      return out
    ]])
    local disk = {}
    for _, id in ipairs(IDS) do
      local f = io.open(stage.log_paths[id], 'r')
      disk[id] = f and f:read('*a') or '<missing>'
      if f then f:close() end
    end
    error('real-hook path failed.\nbuffers: ' .. vim.inspect(snapshot)
      .. '\ndisk: ' .. vim.inspect(disk))
  end
end

-- ---------------------------------------------------------------------------
-- Regression: when peek opens *before* the hook has touched a log file,
-- peek pre-creates the file so `tail -F` has something to watch. That
-- pre-create must produce a file the *owner* can still read AND that a
-- later `tee` (running as the same user) can open for writing — otherwise
-- the wrapped Bash subprocess silently fails and nothing ever streams.
--
-- This test triggers the exact race: spawn three peek floats *before*
-- any producer runs, then run the producers, and assert (a) the resulting
-- on-disk file has owner-rw permissions and (b) the streamed bytes show
-- up in each peek buffer.
-- ---------------------------------------------------------------------------
T['precreate_does_not_block_subsequent_tee_writes'] = function()
  local stage = stage_cache()
  _G.tmp_xdg = stage.xdg

  _G.child = h.spawn({
    config = 'minimal',
    lines = 40,
    columns = 120,
    env = { XDG_CACHE_HOME = stage.xdg, HOME = stage.xdg },
  })
  open_session_with_three_tools(_G.child)

  -- Open peek floats while no log file exists. peek will pre-create each.
  _G.child:lua([[
    local peek = require('cc.peek')
    local buf = vim.fn.bufnr('cc-nvim-output')
    local cands = peek.list_running(buf)
    for _, c in ipairs(cands) do peek.open(buf, c) end
  ]])

  -- File exists now (peek pre-created). Inspect mode: owner MUST have r+w.
  for _, id in ipairs(IDS) do
    local p = stage.log_paths[id]
    eq(vim.fn.filereadable(p), 1)
    local perm = vim.fn.getfperm(p)
    -- First three chars are owner: r, w, then any (x or -).
    if perm:sub(1, 2) ~= 'rw' then
      error(string.format(
        'peek.open pre-created %s with mode %s — owner cannot read/write. '
          .. 'A subsequent `tee` (running as the same user) will get EACCES.',
        p, perm))
    end
  end

  -- Now run the producers (real tee, just like the hook installs). If the
  -- pre-created file has owner-rw, tee can open it for writing; otherwise
  -- it errors out and the log stays at 0 bytes / unreadable.
  local producers = {}
  for i, id in ipairs(IDS) do
    local inner = string.format(
      'for k in 1 2 3 4 5; do printf "race-%d-k%%d\\n" $k; sleep 0.05; done',
      i
    )
    local wrapped = string.format(
      'set -o pipefail; { %s; } 2>&1 | tee %s',
      inner,
      vim.fn.shellescape(stage.log_paths[id])
    )
    table.insert(producers, vim.fn.jobstart({ 'bash', '-c', wrapped }))
  end
  vim.fn.jobwait(producers, 5000)
  vim.wait(200, function() return false end, nil, true)

  -- Each peek buffer should now show the tail of its producer.
  local ok = _G.child:wait_for(function(c)
    return c:lua([[
      local peek = require('cc.peek')
      local n = 0
      for _, pw in pairs(peek._open_peeks) do
        local lines = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
        local found_last = false
        for _, l in ipairs(lines) do
          if type(l) == 'string' and l:find('k5', 1, true) then
            found_last = true; break
          end
        end
        if not found_last then return false end
        n = n + 1
      end
      return n == 3
    ]])
  end, 4000)

  if not ok then
    local snapshot = _G.child:lua([[
      local peek = require('cc.peek')
      local out = {}
      for id, pw in pairs(peek._open_peeks) do
        out[id] = vim.api.nvim_buf_get_lines(pw.bufnr, 0, -1, false)
      end
      return out
    ]])
    local disk = {}
    for _, id in ipairs(IDS) do
      disk[id] = {
        size = vim.fn.getfsize(stage.log_paths[id]),
        perm = vim.fn.getfperm(stage.log_paths[id]),
      }
    end
    error('precreate-then-stream race failed.\nbuffers: ' .. vim.inspect(snapshot)
      .. '\ndisk: ' .. vim.inspect(disk))
  end
end

return T
