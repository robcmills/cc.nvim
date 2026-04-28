-- Statusline rendered at the bottom of the output window. Requires
-- laststatus=2 so every window renders its own statusline (the Neovim
-- default is 3, a single global statusline at screen bottom). With this
-- setup the output window's statusline doubles as the visual separator
-- between output and prompt — the regular winseparator is not drawn on
-- rows that already hold a statusline.
--
-- Uses a `%!` expression that calls back into this module via a
-- winid -> instance map so the callback has no closure baggage.

local M = {}

---@type table<integer, cc.Instance>
local winid_to_instance = {}

---@type table<integer, boolean>
local user_format_errored = {}

---@param n number?
---@return string
local function fmt_tokens(n)
  if not n or n <= 0 then return '' end
  if n >= 1000 then
    return string.format('%.1fk', n / 1000):gsub('%.0k$', 'k')
  end
  return tostring(n)
end

---@param ms number?
---@return string
local function fmt_elapsed(ms)
  if type(ms) ~= 'number' or ms < 0 then return '' end
  local total_s = math.floor(ms / 1000)
  if total_s < 60 then return string.format('%ds', total_s) end
  local minutes = math.floor(total_s / 60)
  local seconds = total_s % 60
  if minutes < 60 then return string.format('%dm %ds', minutes, seconds) end
  local hours = math.floor(minutes / 60)
  minutes = minutes % 60
  return string.format('%dh %dm', hours, minutes)
end

local HL_LINE    = '%#CcStl#'
local HL_TOKENS  = '%#CcStlTokens#'
local HL_MODE    = '%#CcStlMode#'
local HL_EFFORT  = '%#CcStlEffort#'
local HL_BRANCH  = '%#CcStlBranch#'
local HL_SESSION = '%#CcStlSession#'
local SEP = HL_LINE .. ' ── '

---@param state table
---@return string
local function default_format(state)
  local segments = {}
  if state.interrupt_pending then
    table.insert(segments, HL_LINE .. 'interrupting…')
  elseif state.is_thinking then
    local glyph = state.spinner_frame
    if not glyph or glyph == '' then glyph = '⏳' end
    local seg = HL_LINE .. glyph
    local elapsed = fmt_elapsed(state.turn_elapsed_ms)
    if elapsed ~= '' then seg = seg .. ' (' .. elapsed .. ')' end
    table.insert(segments, seg)
  end
  local toks = fmt_tokens(state.total_tokens)
  if toks ~= '' then
    table.insert(segments, HL_TOKENS .. toks .. ' tokens')
  end
  if state.mode and state.mode ~= '' then
    table.insert(segments, HL_MODE .. state.mode .. ' mode')
  end
  if state.effort and state.effort ~= '' then
    local Effort = require('cc.effort')
    local sym = Effort.symbol(state.effort)
    local lbl = Effort.label(state.effort)
    local seg = HL_EFFORT
    if sym ~= '' then seg = seg .. sym .. ' ' end
    table.insert(segments, seg .. lbl)
  end
  if state.branch and state.branch ~= '' then
    local b = HL_BRANCH .. ' ' .. state.branch
    if state.pr and state.pr ~= '' then
      b = b .. ' ' .. state.pr
    end
    table.insert(segments, b)
  end
  if state.session_name and state.session_name ~= '' then
    table.insert(segments, HL_SESSION .. state.session_name)
  end
  if state.remote_control then
    table.insert(segments, HL_LINE .. '⚡')
  end
  -- %= pushes all content to the right; the left side is filled with the
  -- 'stl' fillchar (─, set by output.lua window opts). Trailing space after
  -- the last segment lets the line visually close with one fill unit before
  -- the window edge.
  if #segments == 0 then return HL_LINE .. '%=─' end
  return HL_LINE .. '%= ' .. table.concat(segments, SEP) .. HL_LINE .. ' '
end

---@param instance cc.Instance
---@return table state
function M.build_state(instance)
  local session = instance and instance.session
  local on_update = function()
    pcall(M.refresh, instance)
  end
  local input_tokens = session and session.input_tokens or 0
  local output_tokens = session and session.output_tokens or 0
  local spinner_frame = ''
  if instance then
    local ok, Spinner = pcall(require, 'cc.statusline_spinner')
    if ok then spinner_frame = Spinner.current_frame(instance) end
  end
  local turn_elapsed_ms = nil
  if session and session.turn_active and session.turn_started_at then
    local uv = vim.uv or vim.loop
    turn_elapsed_ms = uv.now() - session.turn_started_at
  end
  return {
    is_thinking = session and session.turn_active or false,
    spinner_frame = spinner_frame,
    turn_elapsed_ms = turn_elapsed_ms,
    interrupt_pending = session and session.interrupt_pending or false,
    total_tokens = input_tokens + output_tokens,
    input_tokens = input_tokens,
    output_tokens = output_tokens,
    cost_usd = session and session.cost_usd or 0,
    mode = session and session.permission_mode or nil,
    branch = require('cc.git').branch(on_update),
    pr = require('cc.git').pr(on_update),
    effort = require('cc.effort').get(),
    model = session and session.model or nil,
    cli_version = require('cc.version').get(on_update),
    session_name = instance and instance.session_name or nil,
    session_id = instance and instance.last_session_id or nil,
    remote_control = instance and instance.remote_control_active == true,
  }
end

---@param instance cc.Instance
---@return string
function M.render(instance)
  if not instance then return '' end
  local cfg = require('cc.config').options.statusline or {}
  local state = M.build_state(instance)
  local fmt = cfg.format
  if type(fmt) == 'function' then
    local ok, result = pcall(fmt, state)
    if ok and type(result) == 'string' then
      return result
    end
    -- Log once per instance, then fall back to default.
    if not user_format_errored[instance] then
      user_format_errored[instance] = true
      vim.schedule(function()
        vim.notify(
          'cc.nvim statusline format errored; using default. ' .. tostring(result),
          vim.log.levels.WARN
        )
      end)
    end
  end
  return default_format(state)
end

--- Global entry point invoked by the `%!` statusline expression.
---@param winid integer
---@return string
function M.render_for(winid)
  local inst = winid_to_instance[winid]
  if not inst then return '' end
  return M.render(inst)
end

-- Expose for vimscript callback.
_G.__cc_statusline_render_for = M.render_for

-- winhighlight is owned by output.lua's window-opts autocmd (see comment
-- below). Saving it here would snapshot cc's value rather than the user's,
-- because attach() runs after that autocmd has already overwritten it.
local STATUSLINE_WIN_OPTS = { 'statusline' }

--- Attach the cc statusline to the given output window. Idempotent.
---@param instance cc.Instance
---@param winid integer
function M.attach(instance, winid)
  local cfg = require('cc.config').options.statusline or {}
  if not cfg.enabled then return end
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  -- laststatus values 0/1 hide per-window statuslines; 3 renders one global
  -- statusline at screen bottom mirroring the current window's format. Only
  -- 2 gives the output window its own statusline at its own bottom edge.
  if vim.o.laststatus ~= 2 then
    vim.o.laststatus = 2
  end
  winid_to_instance[winid] = instance
  require('cc.winopts').save(winid, 'statusline', STATUSLINE_WIN_OPTS)
  vim.wo[winid].statusline =
    "%!v:lua.require'cc.statusline'.render_for(" .. winid .. ')'
  -- stl fillchar (─) and winhighlight (StatusLine:CcStl,StatusLineNC:CcStl
  -- alongside Folded:CcFolded) are both owned by output.lua's window-opts
  -- autocmd, which composes them based on cc.config.statusline.enabled.
  -- Mapping StatusLineNC→CcStl keeps the statusline stable when focus
  -- moves to the prompt (otherwise some terminals drop the trailing ─
  -- fill cells on the NC swap).
  local group = vim.api.nvim_create_augroup('cc.statusline.win.' .. winid, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(winid),
    callback = function()
      winid_to_instance[winid] = nil
      pcall(vim.api.nvim_del_augroup_by_name, 'cc.statusline.win.' .. winid)
    end,
  })
end

--- Undo attach: restore the window's prior statusline. Called when the cc
--- buffer is replaced in the window so the statusline callback doesn't
--- keep rendering for an unrelated buffer. winhighlight is restored by
--- output.lua's BufWinLeave handler, not here.
---@param winid integer
function M.detach(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  winid_to_instance[winid] = nil
  require('cc.winopts').restore(winid, 'statusline', STATUSLINE_WIN_OPTS)
  pcall(vim.api.nvim_del_augroup_by_name, 'cc.statusline.win.' .. winid)
end

--- Force a statusline/winbar redraw for any window tied to this instance.
---@param instance cc.Instance
function M.refresh(instance)
  if not instance then return end
  local cfg = require('cc.config').options.statusline or {}
  if not cfg.enabled then return end
  for winid, inst in pairs(winid_to_instance) do
    if inst == instance and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_call, winid, function()
        vim.cmd('redrawstatus')
      end)
    end
  end
end

--- Test helper: clear all per-winid state.
function M._reset()
  winid_to_instance = {}
  user_format_errored = {}
end

M._default_format = default_format
M._fmt_tokens = fmt_tokens
M._fmt_elapsed = fmt_elapsed

return M
