-- Tracks whether the user has viewed an instance since its last turn finished.
-- Two wall-clock stamps decide it: `session.turn_finished_at` (set by
-- Session:finish_turn) and `inst.output_seen_at` (set here). Entering the
-- output or prompt buffer always counts as a view. A turn that finishes while
-- its buffer is current counts only if Neovim has focus, so an agent that
-- finishes in a tmux window you are not looking at stays unread (tmux
-- focus-events deliver FocusLost/FocusGained).

local M = {}
local nvim_focused = true

---@param inst cc.Instance?
function M.mark_seen(inst)
  if not inst then return end
  local seconds, microseconds = (vim.uv or vim.loop).gettimeofday()
  inst.output_seen_at = (seconds * 1000) + math.floor(microseconds / 1000)
  inst.marked_unread = nil
  require('cc.state_events').check(inst)
end

--- Flag the instance unread until it is next viewed, like Slack's "Mark
--- unread". Busier states (waiting, working, monitoring) still take
--- precedence; the flag shows once the agent is idle.
---@param inst cc.Instance?
function M.mark_unread(inst)
  if not inst then return end
  inst.marked_unread = true
  require('cc.state_events').check(inst)
end

---@param inst cc.Instance?
---@return boolean
function M.is_viewing(inst)
  if not inst or not nvim_focused then return false end
  local bufnr = vim.api.nvim_get_current_buf()
  return (inst.output ~= nil and inst.output.bufnr == bufnr)
    or (inst.prompt ~= nil and inst.prompt.bufnr == bufnr)
end

---@param inst cc.Instance?
function M.on_turn_finished(inst)
  if M.is_viewing(inst) then M.mark_seen(inst) end
end

---@param inst cc.Instance?
---@return boolean
function M.has_unseen_output(inst)
  if inst and inst.marked_unread then return true end
  local finished_at = inst and inst.session and inst.session.turn_finished_at
  return type(finished_at) == 'number' and (inst.output_seen_at or 0) < finished_at
end

---@param inst cc.Instance
function M.attach(inst)
  local group = vim.api.nvim_create_augroup('cc.buffer_integration.' .. inst.output.bufnr, { clear = false })
  for _, bufnr in ipairs({ inst.output.bufnr, inst.prompt.bufnr }) do
    vim.api.nvim_create_autocmd('BufEnter', {
      group = group,
      buffer = bufnr,
      callback = function() M.mark_seen(inst) end,
    })
  end
end

local group = vim.api.nvim_create_augroup('cc.seen', { clear = true })
vim.api.nvim_create_autocmd('FocusLost', {
  group = group,
  callback = function() nvim_focused = false end,
})
vim.api.nvim_create_autocmd('FocusGained', {
  group = group,
  callback = function()
    nvim_focused = true
    M.mark_seen(require('cc').find_instance(vim.api.nvim_get_current_buf()))
  end,
})

return M
