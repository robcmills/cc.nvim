#!/usr/bin/env -S nvim -l
-- Fake claude CLI: minimal stream-json control-channel responder for
-- models-update integration tests. Spawned via fake_claude_models.sh.
--
-- Behavior:
--   - control_request(list_models) → canned catalog, including the
--     'default' pseudo-entry that cc.models must skip
--   - any other control_request     → empty success
--   - exits when stdin closes

local function writeln(obj)
  io.write(vim.json.encode(obj) .. '\n')
  io.flush()
end

local MODELS = {
  { value = 'default', resolvedModel = 'claude-test-1',
    displayName = 'Default (recommended)', description = 'default entry',
    supportsEffort = true, supportedEffortLevels = { 'low', 'high' } },
  { value = 'claude-test-1', resolvedModel = 'claude-test-1',
    displayName = 'Test One', description = 'first test model',
    supportsEffort = true, supportedEffortLevels = { 'low', 'high' } },
  { value = 'test-two', resolvedModel = 'claude-test-2',
    displayName = 'Test Two', description = 'second test model' },
}

while true do
  local line = io.read('*l')
  if not line then break end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(msg) == 'table' and msg.type == 'control_request' then
    local subtype = msg.request and msg.request.subtype
    if subtype == 'list_models' then
      writeln({ type = 'control_response', response = {
        subtype = 'success', request_id = msg.request_id,
        response = { models = MODELS },
      } })
    else
      writeln({ type = 'control_response', response = {
        subtype = 'success', request_id = msg.request_id,
        response = vim.empty_dict(),
      } })
    end
  end
end
