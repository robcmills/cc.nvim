-- nvim-cmp source for cc.nvim slash commands.
-- Active only in cc-chat prompt buffers; triggered by '/' at the start of a line.

local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:get_debug_name() return 'cc_slash' end

function M:is_available()
  local ok, cc = pcall(require, 'cc')
  return ok and cc.find_instance(vim.api.nvim_get_current_buf()) ~= nil
end

function M:get_trigger_characters() return { '/' } end

function M:get_keyword_pattern()
  -- Match /commands (including dashes): /co, /commit, /foo-bar
  return [[/[%w%-_]*]]
end

--- Return {word, abbr, menu, ...} for each command available to this session.
function M:complete(params, callback)
  local line_before = (params.context and params.context.cursor_before_line) or ''
  -- Only complete when the cursor's slash is the first non-space char on the line.
  if not line_before:match('^%s*/[%w%-_]*$') then
    callback({ items = {}, isIncomplete = false })
    return
  end

  -- Grab the current session's slash_commands, if any.
  local session_cmds = nil
  local ok, cc = pcall(require, 'cc')
  if ok then
    local inst = cc.find_instance(vim.api.nvim_get_current_buf())
    if inst and inst.session and inst.session.slash_commands then
      session_cmds = inst.session.slash_commands
    end
  end

  local cmds = require('cc.slash').list(session_cmds)

  local items = {}
  for _, c in ipairs(cmds) do
    table.insert(items, {
      label = '/' .. c.name,
      insertText = c.name, -- '/' is the trigger, already in the buffer
      detail = c.description or c.source,
      kind = 1, -- Text
    })
  end
  callback({ items = items, isIncomplete = false })
end

return M
