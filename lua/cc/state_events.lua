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
  -- A delegating parent pings its children at its own turn boundary.
  local ok, err = pcall(require('cc.delegation').on_state_changed, inst, state, previous)
  if not ok then
    vim.notify('cc.nvim: delegation update failed: ' .. tostring(err), vim.log.levels.DEBUG)
  end
end

--- Fire a final `CcStateChanged` with `state = 'exited'` and `closed = true`
--- for an instance that is being closed. Closing removes the instance
--- before any refresh could notice, so without this a subscriber would never
--- hear that the instance is gone. Fires once per instance.
---@param inst cc.Instance?
function M.closed(inst)
  if not inst or not inst.output or inst.closed_emitted then return end
  inst.closed_emitted = true
  local previous = inst.last_emitted_state
  inst.last_emitted_state = 'exited'
  pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = 'CcStateChanged',
    modeline = false,
    data = {
      bufnr = inst.output.bufnr,
      prompt_bufnr = inst.prompt and inst.prompt.bufnr or nil,
      state = 'exited',
      previous = previous,
      closed = true,
    },
  })
end

return M
