-- Floating-window permission prompt. Replaces vim.ui.select for tool
-- permission requests so the user sees the full tool input (command, diff,
-- query, …) before deciding. Modelled on lua/cc/peek.lua and lua/cc/picker.lua.
--
-- Keymaps (normal mode, buffer-local):
--   a       Allow (once)
--   A       Always Allow (persists via updatedPermissions)
--   d       Deny
--   q/<Esc> Cancel (treated as Deny)
-- Closing the window externally (BufWipeout) also resolves as Deny.
-- The returned handle's dismiss() closes it without answering when resolved remotely.

local M = {}

local tool_body = require('cc.output.tool_body')

--- Default fallback for Bash with no command.
local NO_INPUT = { '(no input)' }

--- Per-tool filetype for the float buffer.
---@param tool_name string
---@return string
local function filetype_for(tool_name)
  if tool_name == 'Bash' then return 'bash' end
  if tool_name == 'Edit' or tool_name == 'MultiEdit' or tool_name == 'Write' then
    return 'diff'
  end
  return ''
end

--- Strip the 8-space leading indent that diff.lua adds. Lets `ft=diff`
--- highlight +/- markers at column 0.
---@param lines string[]
---@return string[]
local function strip_diff_indent(lines)
  local out = {}
  for i, l in ipairs(lines) do
    if l:sub(1, 8) == '        ' then
      out[i] = l:sub(9)
    else
      out[i] = l
    end
  end
  return out
end

--- Body lines to show in the float.
---@param tool_name string
---@param input table?
---@return string[]
local function body_lines(tool_name, input)
  if not input or type(input) ~= 'table' then return NO_INPUT end
  local body = tool_body.default_tool_body(tool_name, input)
  local lines
  if type(body) == 'table' and type(body.lines) == 'table' then
    lines = body.lines
  elseif type(body) == 'table' then
    lines = body
  end
  if not lines or #lines == 0 then return NO_INPUT end
  if tool_name == 'Edit' or tool_name == 'MultiEdit' or tool_name == 'Write' then
    lines = strip_diff_indent(lines)
  end
  return lines
end

--- Title for the float: tool name + description / summary suffix.
---@param tool_name string
---@param input table?
---@return string
local function build_title(tool_name, input)
  local summary
  if type(input) == 'table' then
    if type(input.description) == 'string' and input.description ~= '' then
      summary = input.description
    end
  end
  if not summary or summary == '' then
    summary = tool_body.summarize_tool_input(tool_name, input)
  end
  local title = '⚠ Permission: ' .. tool_name
  if summary and summary ~= '' then
    summary = summary:gsub('\n', ' ')
    if #summary > 100 then summary = summary:sub(1, 97) .. '...' end
    title = title .. ' — ' .. summary
  end
  return title
end
M._build_title = build_title
M._body_lines = body_lines

---@param tool_name string
---@param input table?
---@param context table? request context, including provider and instance
---@return cc.PermissionPromptEvent
local function build_event(tool_name, input, context)
  context = context or {}
  local instance = context.instance
  local stage = context.stage
  local output = instance and instance.output
  local prompt = instance and instance.prompt
  local output_bufnr = output and output.bufnr or nil
  local output_bufname
  if output_bufnr and vim.api.nvim_buf_is_valid(output_bufnr) then
    local name = vim.api.nvim_buf_get_name(output_bufnr)
    if name ~= '' then output_bufname = vim.fn.fnamemodify(name, ':t') end
  end

  return {
    provider = context.provider or 'unknown',
    session_id = instance
      and (instance.last_session_id or (instance.session and instance.session.id))
      or nil,
    session_name = instance
      and (instance.session_name or instance.pending_session_name)
      or nil,
    prompt_bufnr = prompt and prompt.bufnr or nil,
    output_bufnr = output_bufnr,
    output_bufname = output_bufname,
    tool_name = tool_name,
    input = input,
    request_id = context.request_id,
    opened_at = context.opened_at,
    elapsed = context.started_at and (vim.uv.hrtime() - context.started_at) / 1e9 or nil,
    stage = context.stage,
    resolve = context.resolve,
    enable_remote = context.enable_remote and function() return context.enable_remote(stage) end or nil,
    disable_remote = context.disable_remote,
    remote_enabled_by_stage = context.remote_enabled_by_stage,
    behavior = context.behavior,
    source = context.source,
  }
end

local function notify_callback(name, callback, event)
  if type(callback) ~= 'function' then return end
  local ok, err = pcall(callback, event)
  if not ok then
    vim.notify('cc.nvim: ' .. name .. ' callback failed: ' .. tostring(err),
      vim.log.levels.ERROR)
  end
end

---@class cc.PendingPermission
---@field request_id string|number
---@field tool_name string
---@field input table?
---@field opened_at number
---@field remote_enabled_by_stage boolean
---@field resolve fun(behavior: 'allow'|'deny', message: string?): boolean
---@field finish fun(behavior: 'allow'|'deny'|nil, source: string, variant: string?, message: string?, deferred: boolean?): boolean
---@field dismiss fun()?

--- Own a request independently of its float. Providers encode answers in
--- on_choice; remote/closed completions must not send another answer.
---@param tool_name string
---@param input table?
---@param on_choice fun(behavior: string?, variant: string?, message: string?, source: string)
---@param context table provider, instance, request_id, and optional pending map
---@return cc.PendingPermission
function M.request(tool_name, input, on_choice, context)
  local options = require('cc.config').options
  local stages = vim.deepcopy(options.permission_timeouts or {})
  local inst = context.instance
  local pending = context.pending or (inst and inst.pending_permissions) or {}
  if inst then inst.pending_permissions = pending end
  local entry = {
    request_id = context.request_id, tool_name = tool_name, input = input,
    opened_at = os.time(), remote_enabled_by_stage = false,
  }
  context.opened_at = entry.opened_at
  context.started_at = vim.uv.hrtime()
  local resolved, timer, handle = false, nil, nil

  local function stop_timer()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end

  local function refresh()
    if not inst then return end
    inst.awaiting_permission = next(pending) ~= nil
    inst.awaiting_input = inst.awaiting_permission
    require('cc.statusline').refresh(inst)
  end

  entry.finish = function(behavior, source, variant, message, deferred)
    if resolved then return false end
    resolved = true
    stop_timer()
    pending[entry.request_id] = nil
    if source ~= 'local' and handle and handle.dismiss then pcall(handle.dismiss) end
    refresh()
    local function complete()
      on_choice(behavior, variant, message, source)
      context.stage = nil
      context.behavior = behavior
      context.source = source
      context.remote_enabled_by_stage = entry.remote_enabled_by_stage
      notify_callback('on_permission_resolved', options.on_permission_resolved,
        build_event(tool_name, input, context))
    end
    if deferred then vim.schedule(complete) else complete() end
    return true
  end
  entry.resolve = function(behavior, message)
    if behavior ~= 'allow' and behavior ~= 'deny' then return false end
    return entry.finish(behavior, 'api', behavior == 'allow' and 'allow_once' or 'deny', message)
  end
  context.resolve = entry.resolve
  context.enable_remote = function(stage)
    if resolved or not inst or not inst.provider or not inst.provider.set_remote_control then
      return false
    end
    local state = inst.session and inst.session.remote_control_state
    if state == 'ready' or state == 'connected' or state == 'reconnecting'
        or inst.permission_remote_enabling then return false end
    inst.permission_remote_enabling = true
    local id = inst.provider:set_remote_control(true, require('cc')._current_session_name(inst), function()
      inst.permission_remote_enabling = nil
      require('cc.statusline').refresh(inst)
    end)
    if not id then inst.permission_remote_enabling = nil; return false end
    if stage then entry.remote_enabled_by_stage = true end
    return true
  end
  context.disable_remote = function()
    if not inst or not inst.provider or not inst.provider.set_remote_control then return false end
    local id = inst.provider:set_remote_control(false, nil, function()
      inst.permission_remote_enabling = nil
      require('cc.statusline').refresh(inst)
    end)
    return id ~= nil
  end
  context.choose = function(behavior, variant)
    entry.finish(behavior, 'local', variant, nil, true)
  end
  context.set_handle = function(value) handle = value end
  pending[entry.request_id] = entry
  refresh()

  -- Arm one timer at a time. A late event loop or a slow callback must not
  -- make the next stage fire early relative to the preceding stage.
  local function arm(index, delay)
    local stage = stages[index]
    if resolved or not stage then return end
    timer = vim.uv.new_timer()
    timer:start(math.max(0, math.ceil((delay or stage.after) * 1000)), 0, vim.schedule_wrap(function()
      if resolved then return end
      stop_timer()
      local fired_at = vim.uv.hrtime()
      context.stage = index
      notify_callback('permission_timeouts[' .. index .. ']', stage.callback,
        build_event(tool_name, input, context))
      context.stage = nil
      local next_stage = stages[index + 1]
      if next_stage then
        arm(index + 1, next_stage.after - (vim.uv.hrtime() - fired_at) / 1e9)
      end
    end))
  end
  handle = M.ask(tool_name, input, function(behavior, variant)
    entry.finish(behavior, 'local', variant)
  end, context)
  entry.dismiss = handle and handle.dismiss
  -- ask can resolve synchronously, including from on_permission_prompt.
  if resolved then
    if context.source ~= 'local' and handle and handle.dismiss then pcall(handle.dismiss) end
  else
    arm(1, stages[1] and (stages[1].after - (vim.uv.hrtime() - context.started_at) / 1e9))
  end
  return entry
end

--- Close pending requests before tearing down buffers or their process.
---@param instance cc.Instance
function M.close_pending(instance)
  local pending = instance.pending_permissions or {}
  local entries = vim.tbl_values(pending)
  for _, entry in ipairs(entries) do
    if entry.finish then entry.finish('deny', 'closed') end
  end
  instance.permission_remote_enabling = nil
end

--- Open the float and resolve once via `on_choice`.
---
--- `variant` distinguishes the four user choices so callers can build
--- different response payloads. `'allow_once'` is the plain Allow (no
--- persistence); `'allow_always'` means the caller should add the rule to
--- the CLI's permission context via `updatedPermissions`; `'deny'` is an
--- explicit deny; `'cancel'` is treated as a deny but classified
--- differently for telemetry.
---@param tool_name string
---@param input table?
---@param on_choice fun(behavior: 'allow'|'deny', variant: 'allow_once'|'allow_always'|'deny'|'cancel')
---@param context table? request context, including provider and instance
---@return { bufnr: integer, winid: integer, dismiss: fun() }
function M.ask(tool_name, input, on_choice, context)
  local lines = body_lines(tool_name, input)
  local title = build_title(tool_name, input)
  local footer = ' [a]llow  [A]lways  [d]eny  [q]/<Esc> cancel '

  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local width = math.min(120, math.max(60, math.floor(screen_w * 0.8)))
  local height = math.max(5, math.min(#lines + 2, math.floor(screen_h * 0.7)))
  local row = math.max(0, math.floor((screen_h - height) / 2) - 1)
  local col = math.max(0, math.floor((screen_w - width) / 2))

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  local ft = filetype_for(tool_name)
  if ft ~= '' then
    pcall(function() vim.bo[bufnr].filetype = ft end)
  end

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = { { ' ' .. title .. ' ', 'CcPermission' } },
    title_pos = 'center',
    footer = footer,
    footer_pos = 'center',
  })
  vim.wo[winid].wrap = true
  vim.wo[winid].cursorline = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = 'no'

  -- Expose the float so `cc.focus_instance` can land on it instead of the
  -- output window; focusing the output would fire WinLeave and deny.
  local instance = context and context.instance
  if instance then instance.permission_winid = winid end

  local resolved = false
  local function close()
    if instance and instance.permission_winid == winid then
      instance.permission_winid = nil
    end
    if winid and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end

  local function dismiss()
    if resolved then return end
    resolved = true
    close()
  end

  local function resolve(behavior, variant)
    if resolved then return end
    dismiss()
    if context and context.choose then
      context.choose(behavior, variant)
    else
      vim.schedule(function() on_choice(behavior, variant) end)
    end
  end

  local function bind(key, behavior, variant, desc)
    vim.keymap.set('n', key, function() resolve(behavior, variant) end,
      { buffer = bufnr, silent = true, nowait = true,
        desc = 'cc.permission_prompt: ' .. desc })
  end
  bind('a', 'allow', 'allow_once',   'Allow')
  bind('A', 'allow', 'allow_always', 'Always Allow')
  bind('d', 'deny',  'deny',         'Deny')
  bind('q', 'deny',  'cancel',       'Cancel')
  bind('<Esc>', 'deny', 'cancel',    'Cancel')

  -- WinLeave covers the user wandering off (<C-w>w, mouse) and our own
  -- programmatic close; BufWipeout covers :bd / external wipeout.
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = bufnr,
    once = true,
    callback = function() resolve('deny', 'cancel') end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function() resolve('deny', 'cancel') end,
  })

  local handle = { bufnr = bufnr, winid = winid, dismiss = dismiss }
  if context and context.set_handle then context.set_handle(handle) end
  notify_callback('on_permission_prompt', require('cc.config').options.on_permission_prompt,
    build_event(tool_name, input, context))

  return handle
end

return M
