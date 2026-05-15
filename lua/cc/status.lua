-- :CcStatus — render the current session's state in a floating window.
-- Read-only diagnostic view; closes with q or <Esc>.

local M = {}

local NS = vim.api.nvim_create_namespace('cc.status')

local INDENT = '   '
local SECTION_INDENT = ' '
local LABEL_WIDTH = 14

---@class cc.status.Span
---@field col integer 0-based byte column (inclusive)
---@field end_col integer 0-based byte column (exclusive)
---@field hl string highlight group

---@class cc.status.Line
---@field text string buffer line text
---@field spans cc.status.Span[]

---@param label string
---@param value string
---@param value_hl string?
---@return cc.status.Line
local function row(label, value, value_hl)
  value = value or ''
  if value == '' then
    value = '—'
    value_hl = value_hl or 'CcStatusDim'
  end
  value_hl = value_hl or 'CcStatusValue'
  local pad = math.max(1, LABEL_WIDTH - #label)
  local text = INDENT .. label .. string.rep(' ', pad) .. value
  local label_start = #INDENT
  local label_end = label_start + #label
  local value_start = label_end + pad
  return {
    text = text,
    spans = {
      { col = label_start, end_col = label_end, hl = 'CcStatusLabel' },
      { col = value_start, end_col = #text, hl = value_hl },
    },
  }
end

---@param title string
---@return cc.status.Line
local function section(title)
  local text = SECTION_INDENT .. title
  return {
    text = text,
    spans = { { col = #SECTION_INDENT, end_col = #text, hl = 'CcStatusSection' } },
  }
end

---@return cc.status.Line
local function blank()
  return { text = '', spans = {} }
end

---@param n number?
---@return string
local function fmt_tokens(n)
  return require('cc.usage').fmt_compact(n) or ''
end

---@param n number?
---@return string
local function fmt_cost(n)
  if type(n) ~= 'number' or n <= 0 then return '' end
  return string.format('$%.4f', n)
end

---@param ms integer?
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

---@param used integer?
---@param total integer?
---@return string
local function fmt_context(used, total)
  if type(used) ~= 'number' or used <= 0 then return '' end
  local left = fmt_tokens(used)
  if type(total) ~= 'number' or total <= 0 then return left end
  local pct = (used / total) * 100
  return string.format('%s / %s  (%.1f%%)', left, fmt_tokens(total), pct)
end

---@param inst cc.Instance
---@return cc.status.Line[]
function M.build_lines(inst)
  local session = inst and inst.session
  local lines = {}
  local function add(line) table.insert(lines, line) end

  -- Session ---------------------------------------------------------------
  add(section('Session'))
  add(row('id', inst and inst.last_session_id or ''))
  add(row('name', (inst and inst.session_name) or (inst and inst.pending_session_name) or ''))
  add(row('pid', inst and inst.process and tostring(inst.process.pid or '') or ''))

  local state, state_hl
  if not inst or not inst.process then
    state, state_hl = 'idle (no process)', 'CcStatusDim'
  elseif not inst.process:is_alive() then
    state, state_hl = 'exited', 'CcStatusWarn'
  elseif session and session.interrupt_pending then
    state, state_hl = 'interrupting…', 'CcStatusWarn'
  elseif session and session.turn_active then
    local elapsed = fmt_elapsed(session.turn_started_at and ((vim.uv or vim.loop).now() - session.turn_started_at) or nil)
    state = elapsed ~= '' and ('thinking (' .. elapsed .. ')') or 'thinking'
    state_hl = 'CcStatusOK'
  else
    state, state_hl = 'ready', 'CcStatusOK'
  end
  add(row('state', state, state_hl))
  add(blank())

  -- Model -----------------------------------------------------------------
  add(section('Model'))
  add(row('model', session and session.model or ''))
  add(row('permission', session and session.permission_mode or ''))
  local Effort = require('cc.effort')
  local effort_cur = Effort.get()
  local effort_sym = Effort.symbol(effort_cur)
  local effort_lbl = Effort.label(effort_cur)
  local effort_text = effort_sym ~= '' and (effort_sym .. ' ' .. effort_lbl) or effort_lbl
  add(row('effort', effort_text))
  add(row('context', fmt_context(session and session.context_tokens, session and session.context_window)))
  add(blank())

  -- Project ---------------------------------------------------------------
  add(section('Project'))
  add(row('cwd', vim.fn.getcwd()))
  local Git = require('cc.git')
  add(row('branch', Git.branch()))
  add(row('pr', Git.pr()))
  add(blank())

  -- Usage -----------------------------------------------------------------
  add(section('Usage'))
  add(row('input', fmt_tokens(session and session.input_tokens)))
  add(row('output', fmt_tokens(session and session.output_tokens)))
  add(row('cache write', fmt_tokens(session and session.cache_creation_input_tokens)))
  add(row('cache read', fmt_tokens(session and session.cache_read_input_tokens)))
  add(row('cost', fmt_cost(session and session.cost_usd)))
  add(blank())

  -- Runtime ---------------------------------------------------------------
  add(section('Runtime'))
  add(row('plugin', require('cc').VERSION or ''))
  add(row('cli', require('cc.version').get() or ''))
  local n_tools = session and session.tools and #session.tools or 0
  local n_skills = session and session.skills and #session.skills or 0
  local n_slash = session and session.slash_commands and #session.slash_commands or 0
  add(row('tools', n_tools > 0 and tostring(n_tools) or ''))
  add(row('skills', n_skills > 0 and tostring(n_skills) or ''))
  add(row('slash cmds', n_slash > 0 and tostring(n_slash) or ''))

  return lines
end

---@param lines cc.status.Line[]
---@return integer width
local function widest(lines)
  local w = 0
  for _, line in ipairs(lines) do
    local dw = vim.fn.strdisplaywidth(line.text)
    if dw > w then w = dw end
  end
  return w
end

---@param bufnr integer
---@param lines cc.status.Line[]
local function render(bufnr, lines)
  local text = {}
  for _, l in ipairs(lines) do table.insert(text, l.text) end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for i, line in ipairs(lines) do
    for _, span in ipairs(line.spans) do
      vim.api.nvim_buf_set_extmark(bufnr, NS, i - 1, span.col, {
        end_row = i - 1,
        end_col = span.end_col,
        hl_group = span.hl,
      })
    end
  end
  vim.bo[bufnr].modifiable = false
end

--- Open the floating status window for the current cc.nvim instance.
function M.open()
  local cc = require('cc')
  local inst = cc._get_instance()
  if not inst then
    vim.notify('cc.nvim: not focused on a cc buffer (try :CcNew or move into one)',
      vim.log.levels.WARN)
    return
  end

  local lines = M.build_lines(inst)
  local width = math.max(40, widest(lines) + 2)
  width = math.min(width, math.floor(vim.o.columns * 0.9))
  local height = math.min(#lines, math.floor(vim.o.lines * 0.9))

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'cc-status'

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' CcStatus ',
    title_pos = 'center',
  })
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].winhighlight =
    'Normal:CcStatusNormal,FloatBorder:CcStatusBorder,FloatTitle:CcStatusTitle'

  render(bufnr, lines)

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close,
      { buffer = bufnr, silent = true, nowait = true, desc = 'cc-status: close' })
  end
end

-- Test helpers
M._NS = NS

return M
