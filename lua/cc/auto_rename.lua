-- Auto-rename: on the first prompt of a new session, ask the active provider
-- for a short title and apply it via cc._handle_rename (same path as
-- `/rename`). Providers own their CLI command and output contract; this
-- module owns the shared lifecycle, validation, timeout, and UI state.
--
-- Skipped on resumed sessions (they already have a name), on fixtures, and
-- when the user has already renamed (or queued a rename). The rename is
-- best-effort polish: silent on failure, never blocks submit.

local Config = require('cc.config')
local Command = require('cc.command')

local M = {}

---@param path string
---@return string?
local function read_output_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  return table.concat(lines, '\n')
end

--- Substitute `${prompt}` in the auto-rename template. `gsub`'s replacement
--- string interprets `%` sequences, which would corrupt prompts containing
--- literal `%1` (etc.); using a function replacement bypasses that.
---@param template string
---@param prompt_text string?
---@return string
function M.render_prompt(template, prompt_text)
  return (template:gsub('%${prompt}', function() return prompt_text or '' end))
end

--- Default sanitizer for the model's stdout: trim, strip surrounding quotes,
--- drop everything after the first newline (some models append explanatory
--- text on subsequent lines), cap at 64 chars. Returns nil for empty input.
---@param raw string?
---@return string?
function M.default_validate(raw)
  if type(raw) ~= 'string' then return nil end
  local s = raw:match('^%s*(.-)%s*$') or ''
  s = s:match('^[^\r\n]*') or s
  s = s:match('^%s*(.-)%s*$') or s
  if s:sub(1, 1) == '"' or s:sub(1, 1) == "'" then s = s:sub(2) end
  if s:sub(-1) == '"' or s:sub(-1) == "'" then s = s:sub(1, -2) end
  s = s:match('^%s*(.-)%s*$') or s
  if s == '' then return nil end
  if #s > 64 then s = s:sub(1, 64) end
  return s
end

--- Decide whether to fire auto-rename on the current submit. Only true on
--- the very first prompt of a brand-new (non-fixture, unnamed) session.
---@param inst cc.Instance
---@return boolean
function M.should_run(inst)
  local cfg = Config.options.auto_rename
  if not cfg or not cfg.enabled then return false end
  if not inst or inst.is_fixture then return false end
  if inst.session_name and inst.session_name ~= '' then return false end
  if inst.pending_session_name and inst.pending_session_name ~= '' then return false end
  if inst.auto_rename_in_flight then return false end
  if not inst.session or not inst.session.turns or #inst.session.turns > 0 then
    return false
  end
  return true
end

--- Clear the transient "naming…" placeholder set by `start()`. Safe to call
--- even when no placeholder is active.
---@param inst cc.Instance
local function clear_placeholder(inst)
  if not inst or not inst.transient_rename_active then return end
  inst.transient_rename_active = nil
  inst.pending_session_name = nil
  pcall(function() require('cc.statusline').refresh(inst) end)
end

--- Fire-and-forget: spawn the active provider's one-shot naming command,
--- then apply its result via `cc._handle_rename`.
--- Best-effort polish — silent on failure, never blocks submit.
---
--- Before spawning, sets a transient placeholder via `cc._handle_rename` so
--- the statusline immediately reflects that a name is being generated. The
--- placeholder is replaced with the model's output on success, or cleared
--- silently on failure / timeout / cancel.
---@param inst cc.Instance
---@param prompt_text string the user's first prompt
function M.start(inst, prompt_text)
  local cfg = Config.options.auto_rename
  if not cfg then return end
  local rendered = M.render_prompt(cfg.prompt or '', prompt_text)
  if rendered == '' then return end
  local provider = inst and inst.provider
  if not provider or type(provider.auto_rename_spec) ~= 'function' then return end
  local ok_spec, spec = pcall(provider.auto_rename_spec, provider, rendered, cfg)
  if not ok_spec or type(spec) ~= 'table' or type(spec.cmd) ~= 'string'
      or type(spec.args) ~= 'table' then
    return
  end

  local uv = vim.uv or vim.loop
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)

  local stdout_chunks = {}
  inst.auto_rename_in_flight = true

  -- Instant statusline feedback: a transient placeholder via the same code
  -- path as `/rename`. Display-only — never persisted, never flushed.
  local placeholder = cfg.placeholder
  if placeholder and placeholder ~= '' then
    pcall(function()
      require('cc')._handle_rename(inst, placeholder, { silent = true, transient = true })
    end)
  end

  local handle
  local exit_code
  local stdout_done = false
  local finished = false

  local function cleanup()
    if type(spec.cleanup) == 'function' then pcall(spec.cleanup) end
  end

  local function finish()
    if finished or exit_code == nil or not stdout_done then return end
    finished = true
    local is_current = inst.auto_rename_handle == handle
    if is_current then
      inst.auto_rename_in_flight = false
      inst.auto_rename_handle = nil
    end

    local raw
    if spec.output_path then
      raw = read_output_file(spec.output_path)
    else
      raw = table.concat(stdout_chunks)
    end
    cleanup()
    pcall(function() if not stdout:is_closing() then stdout:close() end end)
    pcall(function() if not stderr:is_closing() then stderr:close() end end)
    pcall(function() if handle and not handle:is_closing() then handle:close() end end)

    -- A cancelled/replaced worker must never overwrite later UI state.
    if not is_current then return end
    if exit_code ~= 0 then
      clear_placeholder(inst)
      return
    end
    local validate = cfg.validate or M.default_validate
    local ok, name = pcall(validate, raw)
    if not ok or type(name) ~= 'string' or name == '' then
      clear_placeholder(inst)
      return
    end
    -- If a user-initiated rename landed in the meantime, leave it. Our own
    -- transient placeholder doesn't count: it lives in
    -- `pending_session_name` but is marked by `transient_rename_active`.
    if inst.session_name and inst.session_name ~= '' then
      clear_placeholder(inst)
      return
    end
    if inst.pending_session_name and inst.pending_session_name ~= ''
        and not inst.transient_rename_active then
      return
    end
    -- _handle_rename clears transient_rename_active as a side effect.
    require('cc')._handle_rename(inst, name, { silent = true })
  end

  local executable, resolved_args = Command.resolve(spec.cmd, spec.args)
  handle = uv.spawn(executable, {
    args = resolved_args,
    stdio = { nil, stdout, stderr },
    cwd = vim.fn.getcwd(),
  }, function(code, _signal)
    vim.schedule(function()
      exit_code = code
      finish()
    end)
  end)

  if not handle then
    inst.auto_rename_in_flight = false
    clear_placeholder(inst)
    cleanup()
    pcall(function() stdout:close() end)
    pcall(function() stderr:close() end)
    return
  end

  inst.auto_rename_handle = handle

  stdout:read_start(function(err, data)
    if data then
      table.insert(stdout_chunks, data)
    elseif err or data == nil then
      stdout_done = true
      vim.schedule(finish)
    end
  end)
  -- Discard stderr; auto-rename failures are silent by design.
  stderr:read_start(function(_err, _data) end)

  local timeout_ms = tonumber(cfg.timeout_ms) or 30000
  vim.defer_fn(function()
    if inst.auto_rename_handle == handle and not handle:is_closing() then
      pcall(function() uv.process_kill(handle, 'sigterm') end)
    end
  end, timeout_ms)
end

--- Kill an in-flight auto-rename subprocess (used by close_instance).
---@param inst cc.Instance
function M.cancel(inst)
  local h = inst and inst.auto_rename_handle
  if h and not h:is_closing() then
    pcall(function() (vim.uv or vim.loop).process_kill(h, 'sigterm') end)
  end
  if inst then
    inst.auto_rename_handle = nil
    inst.auto_rename_in_flight = false
    clear_placeholder(inst)
  end
end

return M
