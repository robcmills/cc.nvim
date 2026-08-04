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
---@param context { provider: string?, instance: cc.Instance? }?
---@return cc.PermissionPromptEvent
local function build_event(tool_name, input, context)
  context = context or {}
  local instance = context.instance
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
  }
end

---@param tool_name string
---@param input table?
---@param context { provider: string?, instance: cc.Instance? }?
local function notify_callback(tool_name, input, context)
  local callback = require('cc.config').options.on_permission_prompt
  if type(callback) ~= 'function' then return end
  local ok, err = pcall(callback, build_event(tool_name, input, context))
  if not ok then
    vim.notify('cc.nvim: on_permission_prompt callback failed: ' .. tostring(err),
      vim.log.levels.ERROR)
  end
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
---@param context? { provider: string?, instance: cc.Instance? }
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

  local resolved = false
  local function resolve(behavior, variant)
    if resolved then return end
    resolved = true
    if winid and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    vim.schedule(function() on_choice(behavior, variant) end)
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

  notify_callback(tool_name, input, context)

  return { bufnr = bufnr, winid = winid }
end

return M
