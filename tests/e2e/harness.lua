-- E2E harness for cc.nvim: drives a real nvim child over RPC so tests can
-- exercise the live event loop (autocmds, vim.schedule, vim.defer_fn, redraw)
-- and assert against actual viewport state (topline / line('w$') / winline).
--
-- Each child runs in --headless mode with a unique --listen socket so multiple
-- harness instances can run in parallel without colliding. Lines/columns are
-- set explicitly and an `nvim_ui_attach` is performed so redraws (and topline
-- recomputation) match what a real terminal user would see.

local uv = vim.uv or vim.loop

local M = {}

local THIS_DIR = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local REPO_ROOT = vim.fn.fnamemodify(THIS_DIR, ':h:h')

M.repo_root = REPO_ROOT
M.fake_claude = REPO_ROOT .. '/tests/fixtures/fake_claude.sh'
M.fake_claude_slow = REPO_ROOT .. '/tests/fixtures/fake_claude_slow.sh'
M.ndjson_dir = REPO_ROOT .. '/tests/fixtures/ndjson'
M.jsonl_dir = REPO_ROOT .. '/tests/fixtures/jsonl'

-- ---------------------------------------------------------------------------
-- Child handle
-- ---------------------------------------------------------------------------

---@class cc.E2EChild
---@field sock string
---@field chan integer
---@field job integer
local Child = {}
Child.__index = Child

---@param code string Lua code; the args table is bound to `...`
---@param args table?
function Child:lua(code, args)
  return vim.rpcrequest(self.chan, 'nvim_exec_lua', code, args or {})
end

---@param expr string vim expression
function Child:eval(expr)
  return vim.rpcrequest(self.chan, 'nvim_eval', expr)
end

---@param cmd string ex command
function Child:cmd(cmd)
  return vim.rpcrequest(self.chan, 'nvim_command', cmd)
end

--- Send raw key sequence (supports <CR>, <Esc>, etc).
---@param keys string
function Child:keys(keys)
  local typed = vim.rpcrequest(self.chan, 'nvim_replace_termcodes', keys, true, false, true)
  vim.rpcrequest(self.chan, 'nvim_feedkeys', typed, 'mtx', false)
end

--- Force a redraw cycle so topline / line('w$') reflect current state.
function Child:redraw()
  vim.rpcrequest(self.chan, 'nvim_command', 'redraw!')
end

--- Block the parent until predicate(child) returns truthy or timeout elapses.
--- Returns true on success, false on timeout. Uses fast_only=true so the
--- parent's vim.schedule queue (notably mini.test's reporter.finish) doesn't
--- run while we wait — otherwise reporter.finish would call `cquit` and kill
--- our child subprocess mid-test.
---@param predicate fun(child: cc.E2EChild): boolean
---@param timeout_ms integer?
---@param poll_ms integer?
function Child:wait_for(predicate, timeout_ms, poll_ms)
  timeout_ms = timeout_ms or 3000
  poll_ms = poll_ms or 25
  local deadline = uv.hrtime() + timeout_ms * 1e6
  while uv.hrtime() < deadline do
    if predicate(self) then return true end
    vim.wait(poll_ms, function() return false end, nil, true)
  end
  return false
end

--- Sleep without yielding to the parent's vim.schedule queue.
function Child:sleep(ms)
  vim.wait(ms, function() return false end, nil, true)
end

--- Find the window currently displaying a buffer by name. Returns winid or nil.
---@param buf_name string
---@return integer?
function Child:find_winid_for_buf(buf_name)
  return self:lua(
    [[
    local name = ...
    local buf = vim.fn.bufnr(name)
    if buf <= 0 then return nil end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then return w end
    end
    return nil
  ]],
    { buf_name }
  )
end

--- Snapshot the viewport state of a window. Forces a redraw first so the
--- numbers are coherent. winid=0 means current window.
---@param winid integer
---@return cc.E2EViewport
function Child:viewport(winid)
  return self:lua(
    [[
    local winid = ...
    vim.cmd('redraw!')
    if winid == 0 or winid == nil then
      winid = vim.api.nvim_get_current_win()
    end
    if not vim.api.nvim_win_is_valid(winid) then
      return { error = 'invalid winid' }
    end
    return vim.api.nvim_win_call(winid, function()
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local view = vim.fn.winsaveview()
      return {
        winid = winid,
        bufnr = bufnr,
        buf_name = vim.api.nvim_buf_get_name(bufnr),
        winheight = vim.api.nvim_win_get_height(winid),
        winwidth = vim.api.nvim_win_get_width(winid),
        last_line = vim.api.nvim_buf_line_count(bufnr),
        cursor_line = vim.api.nvim_win_get_cursor(winid)[1],
        topline = vim.fn.line('w0'),
        botline = vim.fn.line('w$'),
        winline = vim.fn.winline(),
        view = view,
      }
    end)
  ]],
    { winid }
  )
end

--- Tear down the child: close RPC channel, stop the process, remove socket.
function Child:close()
  if self._closed then return end
  self._closed = true
  pcall(vim.rpcnotify, self.chan, 'nvim_command', 'qa!')
  pcall(vim.fn.chanclose, self.chan)
  pcall(vim.fn.jobstop, self.job)
  pcall(vim.fn.jobwait, { self.job }, 1000)
  pcall(os.remove, self.sock)
end

-- ---------------------------------------------------------------------------
-- Spawning
-- ---------------------------------------------------------------------------

local function unique_sock()
  -- Use a short /tmp path to stay under the macOS 104-char sun_path limit.
  local rand = string.format('%06x%06x', math.random(0, 0xffffff), math.random(0, 0xffffff))
  return string.format('/tmp/cc-e2e-%d-%s.sock', uv.os_getpid(), rand)
end

--- Spawn a child nvim wired for cc.nvim e2e tests.
---@param opts { config: string?, lines: integer?, columns: integer?, env: table<string,string>? }?
---@return cc.E2EChild
function M.spawn(opts)
  opts = opts or {}
  local config = opts.config or 'minimal'
  local init_file = REPO_ROOT .. '/tests/' .. config .. '_init.lua'
  if vim.fn.filereadable(init_file) ~= 1 then
    error('e2e: init file not found: ' .. init_file)
  end

  local sock = unique_sock()
  pcall(os.remove, sock)

  -- Inherit current env, then layer overrides.
  local env = {}
  for k, v in pairs(vim.fn.environ()) do env[k] = v end
  if opts.env then
    for k, v in pairs(opts.env) do env[k] = v end
  end

  local args = { 'nvim', '--headless', '--listen', sock }
  if config == 'minimal' then table.insert(args, '--clean') end
  table.insert(args, '-u')
  table.insert(args, init_file)

  -- Capture child stderr for diagnostics; surfaced only on failure.
  local stderr_buf = {}
  local job = vim.fn.jobstart(args, {
    env = env,
    pty = false,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if l ~= '' then table.insert(stderr_buf, l) end
      end
    end,
  })
  if job <= 0 then
    error('e2e: jobstart failed')
  end

  -- Wait for socket to appear (nvim creates it shortly after startup).
  -- fast_only=true keeps mini.test's reporter.finish (also vim.schedule'd)
  -- from running while we wait, which would cquit and kill our child.
  local found = vim.wait(5000, function()
    return uv.fs_stat(sock) ~= nil
  end, 20, true)
  if not found then
    pcall(vim.fn.jobstop, job)
    error('e2e: child nvim never created socket: ' .. sock .. '\nstderr: ' .. table.concat(stderr_buf, '\n'))
  end

  local chan = vim.fn.sockconnect('pipe', sock, { rpc = true })
  if chan == 0 then
    pcall(vim.fn.jobstop, job)
    error('e2e: failed to connect to ' .. sock)
  end

  local child = setmetatable({
    sock = sock,
    chan = chan,
    job = job,
    stderr_buf = stderr_buf,
    _closed = false,
  }, Child)

  local lines = opts.lines or 30
  local columns = opts.columns or 100

  -- We deliberately do NOT call nvim_ui_attach: doing so over the sockconnect
  -- channel turns it into a UI channel and breaks subsequent RPC requests on
  -- it. Viewport math (line('w0'), winsaveview, etc.) works correctly without
  -- a UI as long as we explicitly :redraw! before sampling.
  vim.rpcrequest(child.chan, 'nvim_set_option_value', 'lines', lines, {})
  vim.rpcrequest(child.chan, 'nvim_set_option_value', 'columns', columns, {})

  -- Quiet swap/backup just in case the init didn't already.
  child:lua([[
    vim.o.swapfile = false
    vim.o.backup = false
    vim.o.writebackup = false
    vim.o.undofile = false
    vim.o.more = false
    vim.o.shortmess = vim.o.shortmess .. 'I'
  ]])

  return child
end

-- ---------------------------------------------------------------------------
-- cc.nvim convenience wrappers
-- ---------------------------------------------------------------------------

--- Open a cc.nvim session in the child using fake_claude.sh as the backing
--- subprocess. `fixture_name` (without .ndjson) is set as CC_TEST_FIXTURE in
--- the child *before* cc.open spawns the subprocess (uv.spawn inherits env).
--- When `slow_delay_ms` is set, uses fake_claude_slow.sh which emits one
--- NDJSON line at a time with that delay — exercises real streaming timing.
---@param child cc.E2EChild
---@param fixture_name string
---@param setup_opts table? cc.config overrides + { slow_delay_ms = N }
function M.open_with_fixture(child, fixture_name, setup_opts)
  local fixture_path = M.ndjson_dir .. '/' .. fixture_name .. '.ndjson'
  if vim.fn.filereadable(fixture_path) ~= 1 then
    error('e2e: fixture not found: ' .. fixture_path)
  end
  setup_opts = setup_opts or {}
  local slow = setup_opts.slow_delay_ms
  setup_opts.slow_delay_ms = nil
  local cmd = slow and M.fake_claude_slow or M.fake_claude
  local opts_str = vim.inspect(vim.tbl_extend('force', { claude_cmd = cmd }, setup_opts))
  local delay_str = slow and string.format('vim.env.CC_TEST_DELAY_MS = %q\n', tostring(slow)) or ''
  child:lua(
    string.format(
      [[
    vim.env.CC_TEST_FIXTURE = %q
    %s
    require('cc').setup(%s)
    require('cc').open()
  ]],
      fixture_path,
      delay_str,
      opts_str
    )
  )
end

--- Wait until the cc-output buffer exists and the agent has finished
--- streaming (router cleared streaming flag and process exited).
---@param child cc.E2EChild
---@param timeout_ms integer?
---@return boolean
function M.wait_for_session_end(child, timeout_ms)
  return child:wait_for(function(c)
    return c:lua([[
      local buf = vim.fn.bufnr('cc-output')
      if buf <= 0 then return false end
      -- Check the bottom of the output buffer for the terminal "Session ended" notice.
      local last = vim.api.nvim_buf_line_count(buf)
      local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, last - 5), last, false)
      for _, l in ipairs(lines) do
        if l:find('Session ended', 1, true) then return true end
      end
      return false
    ]])
  end, timeout_ms or 5000)
end

-- ---------------------------------------------------------------------------
-- Viewport assertions
-- ---------------------------------------------------------------------------

local function fmt_view(v)
  return string.format(
    'winid=%s buf=%q win=%dx%d cursor=%d topline=%d botline=%d winline=%d last_line=%d',
    tostring(v.winid),
    v.buf_name or '',
    v.winheight or -1,
    v.winwidth or -1,
    v.cursor_line or -1,
    v.topline or -1,
    v.botline or -1,
    v.winline or -1,
    v.last_line or -1
  )
end

--- Bottom-pin invariant — the conditions a cc.nvim user actually depends on:
---   1. line('w$') == line('$')   (last buffer line is visible)
---   2. cursor is on the last buffer line
--- We deliberately do NOT assert winline == winheight: with wrap=on, the
--- surrounding content's wrap layout may not sum to exactly winheight, so
--- `zb` leaves an unavoidable gap of 1-2 empty screen rows below the last
--- line. That's a layout constraint, not the kind of drift that produces
--- the user-visible "snap to top/middle" bug. Conditions 1+2 catch the
--- real bug class (last line scrolled off the visible area).
---@param child cc.E2EChild
---@param winid integer
function M.assert_pinned_to_bottom(child, winid)
  local v = child:viewport(winid)
  if v.error then error('viewport error: ' .. v.error) end
  if v.botline ~= v.last_line then
    error('not pinned (last line not visible): ' .. fmt_view(v), 2)
  end
  if v.cursor_line ~= v.last_line then
    error('cursor not on last line: ' .. fmt_view(v), 2)
  end
end

--- Assert the cursor is on the last buffer line.
---@param child cc.E2EChild
---@param winid integer
function M.assert_cursor_on_last_line(child, winid)
  local v = child:viewport(winid)
  if v.cursor_line ~= v.last_line then
    error('cursor not on last line: ' .. fmt_view(v), 2)
  end
end

--- One-line dump of viewport state (handy in error messages / debugging).
---@param child cc.E2EChild
---@param winid integer
---@return string
function M.dump_viewport(child, winid)
  return fmt_view(child:viewport(winid))
end

-- ---------------------------------------------------------------------------
-- Streaming stress sampler
-- ---------------------------------------------------------------------------

--- Sample viewport state continuously while the subprocess streams. Returns
--- an array of samples; each sample includes a `stable` flag (true when the
--- buffer's line count was unchanged since the previous sample, i.e. the
--- output has settled between chunks — only stable samples should be checked
--- against the bottom-pin invariant since mid-append states are transiently
--- inconsistent by design).
---
--- Polls every `interval_ms` (default 20) until "Session ended" appears at
--- the buffer tail or `timeout_ms` elapses.
---
---@param child cc.E2EChild
---@param winid integer the output window to sample
---@param opts { interval_ms: integer?, timeout_ms: integer? }?
---@return table[] samples each: { ts, stable, view = cc.E2EViewport }
function M.sample_during_stream(child, winid, opts)
  opts = opts or {}
  local interval = opts.interval_ms or 20
  local timeout = opts.timeout_ms or 10000

  local samples = {}
  local prev_last = -1
  local start = uv.hrtime()
  local ended = false
  local end_check_skip = 0

  while (uv.hrtime() - start) / 1e6 < timeout do
    local v = child:viewport(winid)
    if not v.error then
      local stable = (v.last_line == prev_last)
      table.insert(samples, {
        ts_ms = (uv.hrtime() - start) / 1e6,
        stable = stable,
        view = v,
      })
      prev_last = v.last_line
    end

    -- Cheap end check: peek at the last few buffer lines for "Session ended".
    end_check_skip = end_check_skip + 1
    if end_check_skip >= 4 then
      end_check_skip = 0
      ended = child:lua([[
        local buf = vim.fn.bufnr('cc-output')
        if buf <= 0 then return false end
        local last = vim.api.nvim_buf_line_count(buf)
        local lines = vim.api.nvim_buf_get_lines(buf, math.max(0, last - 5), last, false)
        for _, l in ipairs(lines) do
          if l:find('Session ended', 1, true) then return true end
        end
        return false
      ]])
      if ended then break end
    end

    vim.wait(interval, function() return false end, nil, true)
  end

  -- Drain a few extra samples after end so we capture the post-stream resting state.
  for _ = 1, 6 do
    vim.wait(interval, function() return false end, nil, true)
    local v = child:viewport(winid)
    if not v.error then
      local stable = (v.last_line == prev_last)
      table.insert(samples, {
        ts_ms = (uv.hrtime() - start) / 1e6,
        stable = stable,
        view = v,
      })
      prev_last = v.last_line
    end
  end

  return samples
end

--- Walk a sample trace and assert the bottom-pin invariant on every stable
--- sample taken once the buffer has overflowed the window. Fails on the FIRST
--- offending sample with a 5-sample context window.
--- Uses the same invariant as assert_pinned_to_bottom: botline==last_line
--- AND cursor_line==last_line. (See that function for why we don't assert
--- winline==winheight.)
---@param samples table[] from sample_during_stream
function M.assert_trace_pinned(samples)
  for i, s in ipairs(samples) do
    if s.stable and s.view.last_line >= s.view.winheight then
      local v = s.view
      local broken_reason = nil
      if v.botline ~= v.last_line then
        broken_reason = 'last line not visible'
      elseif v.cursor_line ~= v.last_line then
        broken_reason = 'cursor not on last line'
      end
      if broken_reason then
        local lines = { string.format('viewport invariant broken at sample #%d (t=%.1fms): %s', i, s.ts_ms, broken_reason) }
        local ctx_start = math.max(1, i - 4)
        local ctx_end = math.min(#samples, i + 1)
        for j = ctx_start, ctx_end do
          local mark = (j == i) and '>>>' or '   '
          local sj = samples[j]
          table.insert(lines, string.format('%s [#%d t=%6.1fms stable=%s] %s',
            mark, j, sj.ts_ms, tostring(sj.stable), fmt_view(sj.view)))
        end
        error(table.concat(lines, '\n'), 2)
      end
    end
  end
end

return M
