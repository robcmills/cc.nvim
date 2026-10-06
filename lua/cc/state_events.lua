-- Fires `User CcStateChanged` when an instance's lifecycle state changes, so
-- external UIs can subscribe instead of polling `list_instances()`.
-- State is derived on demand (instance_state.get), so there is no single
-- setter to hook. Instead `check` runs from the paths that already follow
-- every state mutation: statusline.refresh and seen.mark_seen.

local M = {}

---@param inst cc.Instance?
function M.check(inst)
  if not inst or not inst.output then return end
  if vim.in_fast_event() then
    vim.schedule(function() M.check(inst) end)
    return
  end
  local state = require('cc.instance_state').get(inst)
  local previous = inst.last_emitted_state
  if state == previous then return end
  inst.last_emitted_state = state
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'CcStateChanged',
    modeline = false,
    data = {
      bufnr = inst.output.bufnr,
      prompt_bufnr = inst.prompt and inst.prompt.bufnr or nil,
      state = state,
      previous = previous,
    },
  })
  -- Push the new state to this instance's parent, and ping this instance's
  -- children at its own turn boundary (cc.delegation).
  local ok, err = pcall(require('cc.delegation').on_state_changed, inst, state, previous)
  if not ok then
    vim.notify('cc.nvim: delegation update failed: ' .. tostring(err), vim.log.levels.DEBUG)
  end
end

return M
