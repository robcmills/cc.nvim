-- Provider-neutral lifecycle state for a cc.nvim instance.  All user-facing
-- status surfaces and the external inventory API use this module so their
-- precedence cannot drift apart.

local M = {}

---@alias cc.InstanceState 'waiting'|'interrupting'|'working'|'starting'|'ready'|'exited'

---@param inst cc.Instance?
---@return cc.InstanceState
function M.get(inst)
  if not inst or not inst.process or not inst.process:is_alive() then
    return 'exited'
  end
  if inst.awaiting_input then return 'waiting' end
  local session = inst.session
  if session and session.interrupt_pending then return 'interrupting' end
  if session and session.turn_active then return 'working' end
  local session_id = inst.last_session_id or (session and session.id)
  if not session_id or session_id == '' then return 'starting' end
  return 'ready'
end

---@param inst cc.Instance?
---@return integer?
function M.turn_elapsed_ms(inst)
  local session = inst and inst.session
  if not session or not session.turn_active or not session.turn_started_at then
    return nil
  end
  return (vim.uv or vim.loop).now() - session.turn_started_at
end

return M
