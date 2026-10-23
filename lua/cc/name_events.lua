-- Fires `User CcRenamed` when an instance's displayed name changes, so
-- external UIs can subscribe instead of polling `list_instances()`.
-- Like state_events, there is no single setter: `check` runs from the paths
-- that already follow every name mutation, statusline.refresh and
-- cc._apply_session_buf_names.

local M = {}

--- The name `list_instances()` reports, and whether it is auto-rename's
--- display-only placeholder.
---@param inst cc.Instance
---@return string? name
---@return boolean transient
local function displayed(inst)
  if inst.session_name and inst.session_name ~= '' then return inst.session_name, false end
  local pending = inst.pending_session_name
  if pending and pending ~= '' then return pending, inst.transient_rename_active == true end
  return nil, false
end

---@param inst cc.Instance?
function M.check(inst)
  if not inst or not inst.output then return end
  if vim.in_fast_event() then
    vim.schedule(function() M.check(inst) end)
    return
  end
  local name, transient = displayed(inst)
  if name == inst.last_emitted_name and transient == (inst.last_emitted_name_transient == true) then
    return
  end
  local previous = inst.last_emitted_name
  inst.last_emitted_name = name
  inst.last_emitted_name_transient = transient
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'CcRenamed',
    modeline = false,
    data = {
      bufnr = inst.output.bufnr,
      prompt_bufnr = inst.prompt and inst.prompt.bufnr or nil,
      name = name,
      previous = previous,
      transient = transient,
    },
  })
end

return M
