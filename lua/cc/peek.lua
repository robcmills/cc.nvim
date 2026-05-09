-- :CcPeek — tail running Bash tool-call output in a floating window.
--
-- Companion to hooks/cc-peek-wrap.sh, which wraps long-running Bash calls so
-- their stdout/stderr stream to /tmp/cc-peek/<session>/<tool_use_id>.log.
-- This module discovers active wrapped calls from session.tool_calls and
-- live-tails the chosen log file.

local uv = vim.uv or vim.loop

local M = {}

local LOG_ROOT = '/tmp/cc-peek'
local SCRIPT_SOURCE = 'hooks/cc-peek-wrap.sh'
local SCRIPT_INSTALL_DIR = vim.fn.expand('~/.claude/hooks')
local SCRIPT_INSTALL_PATH = SCRIPT_INSTALL_DIR .. '/cc-peek-wrap.sh'
local SETTINGS_PATH = vim.fn.expand('~/.claude/settings.json')

-- Open peek windows keyed by tool_use_id so completion notifications can find
-- and annotate them.
---@class cc.PeekWin
---@field winid integer
---@field bufnr integer
---@field tail_handle userdata? uv_process_t
---@field tail_stdout userdata? uv_pipe_t
---@field tool_use_id string
---@field source_bufnr integer cc output bufnr that owns this peek
---@field done boolean
local _open_peeks = {} ---@type table<string, cc.PeekWin>

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Strip the `tee` wrap added by cc-peek-wrap.sh so the displayed command
--- looks like what the agent actually invoked.
---@param command string
---@return string
function M.strip_wrap(command)
  if type(command) ~= 'string' then return '' end
  local inner = command:match('^set %-o pipefail; %{ (.-); %} 2>&1 | tee /tmp/cc%-peek/[%w%-_]+/[%w%-_]+%.log$')
  return inner or command
end

--- Extract the log path from a wrapped command. Returns nil if not wrapped.
---@param command string?
---@return string?
local function extract_log_path(command)
  if type(command) ~= 'string' then return nil end
  return command:match('(/tmp/cc%-peek/[%w%-_]+/[%w%-_]+%.log)')
end

--- Truncate a string to width with an ellipsis suffix.
---@param s string
---@param width integer
---@return string
local function truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  return s:sub(1, math.max(1, width - 1)) .. '…'
end

-- ---------------------------------------------------------------------------
-- list_running: derive in-flight peekable Bash calls from a session.
-- ---------------------------------------------------------------------------

---@class cc.PeekCandidate
---@field id string tool_use_id
---@field command string command (with wrap stripped)
---@field started integer? vim.uv.now() ms timestamp
---@field log_path string path to the per-tool log file
---@field source_bufnr integer cc output bufnr (for cleanup binding)

--- Enumerate running peekable Bash tool calls for the instance owning bufnr.
---@param bufnr integer cc output buffer number
---@return cc.PeekCandidate[]
function M.list_running(bufnr)
  local cc = require('cc')
  local inst = cc.find_instance and cc.find_instance(bufnr) or nil
  local out = {}
  if not inst or not inst.session or not inst.session.tool_calls then
    return out
  end
  for id, rec in pairs(inst.session.tool_calls) do
    if rec.name == 'Bash' and not rec.result and type(rec.input) == 'table' then
      local log = extract_log_path(rec.input.command)
      if log then
        table.insert(out, {
          id = id,
          command = M.strip_wrap(rec.input.command),
          started = rec.start_time,
          log_path = log,
          source_bufnr = inst.output and inst.output.bufnr or bufnr,
        })
      end
    end
  end
  table.sort(out, function(a, b) return (a.started or 0) < (b.started or 0) end)
  return out
end

-- ---------------------------------------------------------------------------
-- Float + tail
-- ---------------------------------------------------------------------------

---@param title string
---@return integer bufnr, integer winid
local function open_float(title)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'log'
  vim.bo[bufnr].modifiable = false

  local width = math.min(120, math.floor(vim.o.columns * 0.8))
  local height = math.floor(vim.o.lines * 0.7)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  })
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].cursorline = false
  return bufnr, winid
end

---@param peek cc.PeekWin
local function close_peek(peek)
  if peek.tail_handle and not peek.tail_handle:is_closing() then
    pcall(function() peek.tail_handle:kill('sigterm') end)
    pcall(function() peek.tail_handle:close() end)
  end
  if peek.tail_stdout and not peek.tail_stdout:is_closing() then
    pcall(function() peek.tail_stdout:close() end)
  end
  peek.tail_handle = nil
  peek.tail_stdout = nil
  if peek.winid and vim.api.nvim_win_is_valid(peek.winid) then
    pcall(vim.api.nvim_win_close, peek.winid, true)
  end
  _open_peeks[peek.tool_use_id] = nil
end

---@param peek cc.PeekWin
---@param chunk string
local function append_chunk(peek, chunk)
  if not vim.api.nvim_buf_is_valid(peek.bufnr) then return end
  -- Sticky-tail: only auto-scroll if the user is parked on the last line.
  local stick = false
  if peek.winid and vim.api.nvim_win_is_valid(peek.winid)
      and vim.api.nvim_win_get_buf(peek.winid) == peek.bufnr then
    local cur = vim.api.nvim_win_get_cursor(peek.winid)
    local last = vim.api.nvim_buf_line_count(peek.bufnr)
    stick = (cur[1] >= last)
  end

  local lines = vim.split(chunk, '\n', { plain = true })
  vim.bo[peek.bufnr].modifiable = true
  -- Append: merge first chunk-line with current trailing line, then append the
  -- rest as new lines. Empty trailing element from a trailing '\n' is dropped.
  local last_line = vim.api.nvim_buf_line_count(peek.bufnr)
  local trailing = vim.api.nvim_buf_get_lines(peek.bufnr, last_line - 1, last_line, false)[1] or ''
  if #lines > 0 then
    if lines[#lines] == '' then table.remove(lines) end
  end
  if #lines == 0 then
    vim.bo[peek.bufnr].modifiable = false
    return
  end
  lines[1] = trailing .. lines[1]
  vim.api.nvim_buf_set_lines(peek.bufnr, last_line - 1, last_line, false, lines)
  vim.bo[peek.bufnr].modifiable = false

  if stick and peek.winid and vim.api.nvim_win_is_valid(peek.winid)
      and vim.api.nvim_win_get_buf(peek.winid) == peek.bufnr then
    local last = vim.api.nvim_buf_line_count(peek.bufnr)
    pcall(vim.api.nvim_win_set_cursor, peek.winid, { last, 0 })
  end
end

---@param peek cc.PeekWin
---@param footer string
local function annotate_done(peek, footer)
  if not vim.api.nvim_buf_is_valid(peek.bufnr) then return end
  vim.bo[peek.bufnr].modifiable = true
  local last = vim.api.nvim_buf_line_count(peek.bufnr)
  vim.api.nvim_buf_set_lines(peek.bufnr, last, last, false, { '', '── ' .. footer .. ' ──' })
  vim.bo[peek.bufnr].modifiable = false
end

---@param bufnr integer source cc output buffer
---@param candidate cc.PeekCandidate
function M.open(bufnr, candidate)
  -- Already open? Focus it.
  local existing = _open_peeks[candidate.id]
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_set_current_win(existing.winid)
    return
  end

  if vim.fn.filereadable(candidate.log_path) ~= 1 then
    -- Race: hook fired but tool hasn't started writing yet. `tail -F` will
    -- still work (it polls), so create the file pre-emptively to avoid
    -- ENOENT noise.
    local f = io.open(candidate.log_path, 'a')
    if f then f:close() end
  end

  local title = 'CcPeek · ' .. truncate(candidate.command, 60)
  local float_bufnr, float_winid = open_float(title)

  local peek = {
    winid = float_winid,
    bufnr = float_bufnr,
    tool_use_id = candidate.id,
    source_bufnr = candidate.source_bufnr,
    done = false,
  }
  _open_peeks[candidate.id] = peek

  -- Pre-load whatever is already in the file (the tool may have been running
  -- before :CcPeek was invoked).
  local existing_lines = vim.fn.readfile(candidate.log_path)
  if #existing_lines > 0 then
    vim.bo[float_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(float_bufnr, 0, -1, false, existing_lines)
    vim.bo[float_bufnr].modifiable = false
    if float_winid and vim.api.nvim_win_is_valid(float_winid) then
      pcall(vim.api.nvim_win_set_cursor, float_winid,
        { vim.api.nvim_buf_line_count(float_bufnr), 0 })
    end
  end

  -- Spawn `tail -n 0 -F <log>` so we only stream new lines (already loaded
  -- above). -F survives truncation and rotation. -n 0 suppresses the initial
  -- 10-line backfill that `-f` would do.
  local stdout = uv.new_pipe(false)
  local handle, err = uv.spawn('tail', {
    args = { '-n', '0', '-F', candidate.log_path },
    stdio = { nil, stdout, nil },
  }, function() end)
  if not handle then
    vim.notify('cc-peek: failed to spawn tail: ' .. tostring(err), vim.log.levels.ERROR)
    close_peek(peek)
    return
  end
  peek.tail_handle = handle
  peek.tail_stdout = stdout
  uv.read_start(stdout, function(read_err, data)
    if read_err or not data then return end
    vim.schedule(function()
      if _open_peeks[candidate.id] ~= peek then return end
      append_chunk(peek, data)
    end)
  end)

  -- Close the float on q/<Esc>; teardown when the buffer is wiped (covers
  -- :close, :bd, window-closed-by-other-means).
  local function bind_close(key)
    vim.keymap.set('n', key, function() close_peek(peek) end,
      { buffer = float_bufnr, silent = true, nowait = true, desc = 'cc-peek: close' })
  end
  bind_close('q')
  bind_close('<Esc>')

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = float_bufnr,
    once = true,
    callback = function() close_peek(peek) end,
  })
end

-- ---------------------------------------------------------------------------
-- Tool completion / teardown hooks (called from router and init)
-- ---------------------------------------------------------------------------

--- Notify peek that a tool_use has produced a result. If a peek window is
--- watching it, mark it done — leave the window open with a footer so the
--- user can read the final state.
---@param tool_use_id string
---@param is_error boolean?
function M.notify_tool_result(tool_use_id, is_error)
  local peek = _open_peeks[tool_use_id]
  if not peek or peek.done then return end
  peek.done = true
  if peek.tail_handle and not peek.tail_handle:is_closing() then
    pcall(function() peek.tail_handle:kill('sigterm') end)
  end
  vim.schedule(function()
    if not peek then return end
    annotate_done(peek, is_error and 'tool errored' or 'tool finished')
  end)
end

--- Per-bufnr teardown hook. Called from cc.init's instance close paths.
--- Closes any peek windows belonging to this output buffer and removes the
--- session-scoped log dir.
---@param bufnr integer cc output buffer number
---@param session_id string?
function M.teardown(bufnr, session_id)
  for id, peek in pairs(_open_peeks) do
    if peek.source_bufnr == bufnr then
      _open_peeks[id] = nil
      vim.schedule(function() close_peek(peek) end)
    end
  end
  if session_id and session_id ~= '' then
    pcall(vim.fn.delete, LOG_ROOT .. '/' .. session_id, 'rf')
  end
end

-- ---------------------------------------------------------------------------
-- GC: prune stale /tmp/cc-peek/* dirs (other sessions, > 1h old).
-- ---------------------------------------------------------------------------

---@param now integer? seconds since epoch (override for tests)
---@param current_session_id string?
function M.gc(now, current_session_id)
  now = now or os.time()
  local stat = uv.fs_stat(LOG_ROOT)
  if not stat then return end
  local handle = uv.fs_scandir(LOG_ROOT)
  if not handle then return end
  while true do
    local name, t = uv.fs_scandir_next(handle)
    if not name then break end
    if t == 'directory' and name ~= current_session_id then
      local dir = LOG_ROOT .. '/' .. name
      local s = uv.fs_stat(dir)
      if s and (now - s.mtime.sec) > 3600 then
        pcall(vim.fn.delete, dir, 'rf')
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Install / uninstall
-- ---------------------------------------------------------------------------

--- Find the source script in the plugin's runtime path.
---@return string?
local function find_source_script()
  local hits = vim.api.nvim_get_runtime_file(SCRIPT_SOURCE, false)
  if hits and hits[1] then return hits[1] end
  return nil
end

--- Read settings.json into a table. Missing or unreadable → empty table.
---@param path string
---@return table, string? err
local function read_settings(path)
  if vim.fn.filereadable(path) ~= 1 then return {}, nil end
  local lines = vim.fn.readfile(path)
  local raw = table.concat(lines, '\n')
  if raw == '' then return {}, nil end
  local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok then return {}, tostring(decoded) end
  if type(decoded) ~= 'table' then return {}, 'settings.json root is not a JSON object' end
  return decoded, nil
end

--- Atomic-ish write (write to .tmp, rename).
---@param path string
---@param data string
---@return boolean ok, string? err
local function write_file(path, data)
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p')
  local tmp = path .. '.tmp'
  local f, oerr = io.open(tmp, 'w')
  if not f then return false, oerr end
  f:write(data)
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then return false, rerr end
  return true, nil
end

--- Find the index of an existing PreToolUse matcher entry that already wires
--- our hook script. Returns (group_index, hook_index) or nil.
---@param pre_tool_use table[]
---@return integer?, integer?
local function find_existing_entry(pre_tool_use)
  for gi, group in ipairs(pre_tool_use or {}) do
    if type(group) == 'table' and group.matcher == 'Bash' and type(group.hooks) == 'table' then
      for hi, hook in ipairs(group.hooks) do
        if type(hook) == 'table' and hook.command and tostring(hook.command):find('cc%-peek%-wrap%.sh') then
          return gi, hi
        end
      end
    end
  end
  return nil, nil
end

--- :CcPeekInstall — copy hook script into ~/.claude/hooks and register it
--- under PreToolUse for matcher "Bash" in ~/.claude/settings.json.
function M.install()
  local src = find_source_script()
  if not src then
    vim.notify('cc-peek: could not locate ' .. SCRIPT_SOURCE .. ' in runtimepath', vim.log.levels.ERROR)
    return
  end

  vim.fn.mkdir(SCRIPT_INSTALL_DIR, 'p')
  local content = table.concat(vim.fn.readfile(src, 'b'), '\n')
  local ok, err = write_file(SCRIPT_INSTALL_PATH, content)
  if not ok then
    vim.notify('cc-peek: failed to write hook script: ' .. tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.fn.setfperm(SCRIPT_INSTALL_PATH, 'rwxr-xr-x')

  local settings, rerr = read_settings(SETTINGS_PATH)
  if rerr then
    vim.notify('cc-peek: settings.json parse error: ' .. rerr .. ' — install aborted', vim.log.levels.ERROR)
    return
  end
  settings.hooks = settings.hooks or {}
  settings.hooks.PreToolUse = settings.hooks.PreToolUse or {}

  local gi, _ = find_existing_entry(settings.hooks.PreToolUse)
  local hook_entry = {
    type = 'command',
    command = SCRIPT_INSTALL_PATH,
  }
  if gi then
    -- Already present — overwrite the command path in case the user moved
    -- their plugin install. Idempotent.
    settings.hooks.PreToolUse[gi].hooks = { hook_entry }
  else
    table.insert(settings.hooks.PreToolUse, {
      matcher = 'Bash',
      hooks = { hook_entry },
    })
  end

  local encoded = vim.json.encode(settings)
  -- Best-effort pretty: use jq if available, otherwise raw.
  if vim.fn.executable('jq') == 1 then
    local pretty = vim.fn.system({ 'jq', '.' }, encoded)
    if vim.v.shell_error == 0 and pretty ~= '' then encoded = pretty end
  end
  local wok, werr = write_file(SETTINGS_PATH, encoded)
  if not wok then
    vim.notify('cc-peek: failed to write settings.json: ' .. tostring(werr), vim.log.levels.ERROR)
    return
  end

  vim.notify('cc-peek: installed. Restart any running claude sessions to pick up the hook.', vim.log.levels.INFO)
end

--- :CcPeekUninstall — remove the matcher entry from settings.json. Leaves
--- the script file in place (harmless).
function M.uninstall()
  local settings, rerr = read_settings(SETTINGS_PATH)
  if rerr then
    vim.notify('cc-peek: settings.json parse error: ' .. rerr, vim.log.levels.ERROR)
    return
  end
  if not (settings.hooks and settings.hooks.PreToolUse) then
    vim.notify('cc-peek: nothing to uninstall', vim.log.levels.INFO)
    return
  end

  local kept = {}
  local removed = false
  for _, group in ipairs(settings.hooks.PreToolUse) do
    if type(group) == 'table' and group.matcher == 'Bash' and type(group.hooks) == 'table' then
      local kept_hooks = {}
      for _, hook in ipairs(group.hooks) do
        if not (type(hook) == 'table' and hook.command and tostring(hook.command):find('cc%-peek%-wrap%.sh')) then
          table.insert(kept_hooks, hook)
        else
          removed = true
        end
      end
      if #kept_hooks > 0 then
        group.hooks = kept_hooks
        table.insert(kept, group)
      end
    else
      table.insert(kept, group)
    end
  end
  settings.hooks.PreToolUse = kept
  if vim.tbl_isempty(settings.hooks.PreToolUse) then
    settings.hooks.PreToolUse = nil
    if vim.tbl_isempty(settings.hooks) then settings.hooks = nil end
  end

  if not removed then
    vim.notify('cc-peek: not found in settings.json', vim.log.levels.INFO)
    return
  end

  local encoded = vim.json.encode(settings)
  if vim.fn.executable('jq') == 1 then
    local pretty = vim.fn.system({ 'jq', '.' }, encoded)
    if vim.v.shell_error == 0 and pretty ~= '' then encoded = pretty end
  end
  local ok, werr = write_file(SETTINGS_PATH, encoded)
  if not ok then
    vim.notify('cc-peek: failed to write settings.json: ' .. tostring(werr), vim.log.levels.ERROR)
    return
  end
  vim.notify('cc-peek: uninstalled. Hook script left at ' .. SCRIPT_INSTALL_PATH, vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- :CcPeek dispatcher
-- ---------------------------------------------------------------------------

--- Called from :CcPeek. Lists running peekable Bash calls in the current
--- instance and either opens directly (1 candidate), prompts (2+), or
--- notifies (0).
function M.peek_command()
  M.gc(nil, nil)

  local cur_buf = vim.api.nvim_get_current_buf()
  local candidates = M.list_running(cur_buf)
  if #candidates == 0 then
    vim.notify('cc-peek: no peekable Bash running', vim.log.levels.INFO)
    return
  end
  if #candidates == 1 then
    M.open(cur_buf, candidates[1])
    return
  end

  local now = (uv.now and uv.now()) or 0
  vim.ui.select(candidates, {
    prompt = 'CcPeek: pick a running Bash',
    format_item = function(c)
      local elapsed = c.started and math.max(0, math.floor((now - c.started) / 1000)) or 0
      return string.format('%4ds  %s', elapsed, truncate(c.command, 80))
    end,
  }, function(choice)
    if choice then M.open(cur_buf, choice) end
  end)
end

-- For tests
M._open_peeks = _open_peeks

return M
