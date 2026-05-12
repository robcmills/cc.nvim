-- :CcPeek — tail running Bash tool-call output in a floating window.
--
-- Companion to hooks/cc-peek-wrap.sh, which wraps long-running Bash calls so
-- their stdout/stderr stream to <cache_root>/<session>/<tool_use_id>.log,
-- where <cache_root> is $XDG_CACHE_HOME/cc-peek (or ~/.cache/cc-peek). This
-- module discovers active wrapped calls from session.tool_calls and
-- live-tails the chosen log file.

local uv = vim.uv or vim.loop

local M = {}

--- Resolve cache root from XDG_CACHE_HOME / HOME at module load. Re-resolved
--- whenever the module is reloaded (tests do this to redirect HOME).
local function resolve_cache_root()
  return (vim.env.XDG_CACHE_HOME or (vim.env.HOME .. '/.cache')) .. '/cc-peek'
end

M._cache_root = resolve_cache_root()
M._cache_root_pat = vim.pesc(M._cache_root) .. '/[%w%-_]+/[%w%-_]+%.log'

-- Mirrors the >=30000ms threshold in hooks/cc-peek-wrap.sh — only wraps that
-- match here get a log file, so list_running uses the same cutoff.
local WRAP_TIMEOUT_MS = 30000

local SCRIPT_SOURCE = 'hooks/cc-peek-wrap.sh'
local SCRIPT_INSTALL_DIR = vim.fn.expand('~/.claude/hooks')
local SCRIPT_INSTALL_PATH = SCRIPT_INSTALL_DIR .. '/cc-peek-wrap.sh'
local SETTINGS_PATH = vim.fn.expand('~/.claude/settings.json')

local GC_MAX_AGE_SECONDS = 3600

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
---@field partial string trailing bytes from the last chunk that didn't end with '\n'; mirrored as the buffer's last line.
---@field placeholder boolean true while the "waiting for output" lines occupy the buffer; cleared on first real chunk.
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
  local pat = '^set %-o pipefail; %{ (.-); %} 2>&1 | tee ' .. M._cache_root_pat .. '$'
  local inner = command:match(pat)
  return inner or command
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
---
--- The assistant's tool_use content block carries the *original* command from
--- the model — the hook's `updatedInput` wrap is only visible to the bash
--- subprocess, not to the NDJSON stream we ingest. So we identify peekables
--- by mirroring the hook's filter (Bash + timeout >= 30s) and constructing
--- the log path deterministically from <cache_root>/<session_id>/<id>.log.
---@param bufnr integer cc output buffer number
---@return cc.PeekCandidate[]
function M.list_running(bufnr)
  local cc = require('cc')
  local inst = cc.find_instance and cc.find_instance(bufnr) or nil
  local out = {}
  if not inst or not inst.session or not inst.session.tool_calls then
    return out
  end
  local session_id = inst.session.id
  -- Defense in depth: only treat well-formed session IDs as path-safe.
  if type(session_id) ~= 'string' or not session_id:match('^[%w%-_]+$') then
    return out
  end
  for id, rec in pairs(inst.session.tool_calls) do
    if rec.name == 'Bash'
        and not rec.result
        and type(rec.input) == 'table'
        and type(rec.input.timeout) == 'number'
        and rec.input.timeout >= WRAP_TIMEOUT_MS
        and type(id) == 'string' and id:match('^[%w%-_]+$') then
      local log_path = M._cache_root .. '/' .. session_id .. '/' .. id .. '.log'
      table.insert(out, {
        id = id,
        command = rec.input.command or '',
        started = rec.start_time,
        log_path = log_path,
        source_bufnr = inst.output and inst.output.bufnr or bufnr,
      })
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

-- Shown in the float when peek opens on a log file that is empty or
-- missing — usually because Claude hasn't yet launched the wrapped bash
-- subprocess (long-Bash calls can run sequentially). A blank float reads
-- as "broken"; this placeholder makes the waiting state explicit.
local PLACEHOLDER_LINES = {
  '… waiting for tool output …',
  '',
  'The log file is empty. The tool may not have started yet —',
  'Claude can run long Bash calls sequentially. Output will appear',
  'here as soon as the tool begins writing.',
}

---@param peek cc.PeekWin
local function set_placeholder(peek)
  if not vim.api.nvim_buf_is_valid(peek.bufnr) then return end
  vim.bo[peek.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(peek.bufnr, 0, -1, false, PLACEHOLDER_LINES)
  vim.bo[peek.bufnr].modifiable = false
  peek.placeholder = true
end

---@param peek cc.PeekWin
local function clear_placeholder(peek)
  if not vim.api.nvim_buf_is_valid(peek.bufnr) then return end
  vim.bo[peek.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(peek.bufnr, 0, -1, false, { '' })
  vim.bo[peek.bufnr].modifiable = false
  peek.placeholder = false
  peek.partial = ''
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

  -- Invariant: peek.partial holds the trailing bytes since the last '\n',
  -- and it is mirrored as the buffer's last line. We splice in the new
  -- completed lines plus the new partial, replacing only that last line.
  -- This guarantees we never merge across a '\n' boundary (which would
  -- happen if we re-read the buffer's last line and concatenated to it
  -- after a chunk that ended in '\n').
  local combined = (peek.partial or '') .. chunk
  local lines = vim.split(combined, '\n', { plain = true })
  local new_partial = table.remove(lines) or ''
  peek.partial = new_partial
  table.insert(lines, new_partial)

  vim.bo[peek.bufnr].modifiable = true
  local last_line = vim.api.nvim_buf_line_count(peek.bufnr)
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

  -- Refuse to tail anything outside our cache root. The candidate's log_path
  -- already came from extract_log_path (which constrains by pattern), but
  -- double-check before we hand it to `tail`.
  if not candidate.log_path:find('^' .. vim.pesc(M._cache_root) .. '/') then
    vim.notify('cc-peek: refusing to tail path outside cache root: ' .. candidate.log_path,
      vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(candidate.log_path) ~= 1 then
    -- Race: hook fired but tool hasn't started writing yet (or peek opened
    -- before the hook even ran). `tail -F` will still work (it polls), so
    -- create the file pre-emptively to avoid ENOENT noise. mkdir the parent
    -- too in case the hook hasn't staged the session dir yet either.
    local parent = vim.fn.fnamemodify(candidate.log_path, ':h')
    if vim.fn.isdirectory(parent) ~= 1 then
      vim.fn.mkdir(parent, 'p')
    end
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
    partial = '',
    placeholder = false,
  }
  _open_peeks[candidate.id] = peek

  -- If the log is empty/missing at open time, show a "waiting for output"
  -- placeholder. Cleared by the first real chunk in the read_start callback.
  local stat = uv.fs_stat(candidate.log_path)
  if not stat or stat.size == 0 then
    set_placeholder(peek)
  end

  -- Spawn `tail -c +1 -F <log>`: outputs the entire file from byte 1, then
  -- follows new writes. One mechanism for preload AND streaming, so there's
  -- no race window between a synchronous readfile and tail's seek-to-EOF
  -- where freshly-written bytes could be lost. -F survives truncation and
  -- rotation (which `tee` does on first open).
  local stdout = uv.new_pipe(false)
  local handle, err = uv.spawn('tail', {
    args = { '-c', '+1', '-F', candidate.log_path },
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
      if not vim.api.nvim_buf_is_valid(peek.bufnr) then return end
      if peek.placeholder then clear_placeholder(peek) end
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
  -- Defense in depth: only consider session_ids that match our path regex.
  if session_id and session_id:match('^[%w%-_]+$') then
    pcall(vim.fn.delete, M._cache_root .. '/' .. session_id, 'rf')
  end
end

-- ---------------------------------------------------------------------------
-- GC: prune stale <cache_root>/*/ dirs (other sessions, > 1h old).
-- ---------------------------------------------------------------------------

---@param now integer? seconds since epoch (override for tests)
---@param current_session_id string?
function M.gc(now, current_session_id)
  now = now or os.time()
  local stat = uv.fs_stat(M._cache_root)
  if not stat then return end
  local handle = uv.fs_scandir(M._cache_root)
  if not handle then return end
  while true do
    local name, t = uv.fs_scandir_next(handle)
    if not name then break end
    if t == 'directory' and name ~= current_session_id then
      local dir = M._cache_root .. '/' .. name
      local s = uv.fs_stat(dir)
      if s and (now - s.mtime.sec) > GC_MAX_AGE_SECONDS then
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

--- Atomic write via fs_rename. We rename within the same directory so the
--- rename is atomic on POSIX. The temp filename is per-process to keep two
--- concurrent claude sessions from clobbering each other's tmp file.
---@param path string
---@param data string
---@return boolean ok, string? err
local function write_file_atomic(path, data)
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p')
  local tmp = path .. '.cc-peek.tmp.' .. (uv.os_getpid and uv.os_getpid() or vim.fn.getpid())
  local fd, oerr = uv.fs_open(tmp, 'w', tonumber('600', 8))
  if not fd then return false, oerr end
  local wok, werr = uv.fs_write(fd, data)
  uv.fs_close(fd)
  if not wok then
    pcall(uv.fs_unlink, tmp)
    return false, werr
  end
  local rok, rerr = uv.fs_rename(tmp, path)
  if not rok then
    pcall(uv.fs_unlink, tmp)
    return false, rerr
  end
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
  local ok, err = write_file_atomic(SCRIPT_INSTALL_PATH, content)
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
  local wok, werr = write_file_atomic(SETTINGS_PATH, encoded)
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
  local ok, werr = write_file_atomic(SETTINGS_PATH, encoded)
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
  local cur_buf = vim.api.nvim_get_current_buf()

  -- GC is bounded — scan the cache root once per invocation.
  local cc = require('cc')
  local inst = cc.find_instance and cc.find_instance(cur_buf) or nil
  local current_sid = inst and inst.session and inst.session.id or nil
  M.gc(nil, current_sid)

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
M._append_chunk = append_chunk
M._set_placeholder = set_placeholder
M._clear_placeholder = clear_placeholder
M._PLACEHOLDER_LINES = PLACEHOLDER_LINES

return M
