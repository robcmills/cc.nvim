-- Advisor tool blocks. The CLI's server-side `advisor` tool streams as a
-- `server_tool_use` block (name "advisor", empty input) followed by an
-- `advisor_tool_result` block in the same assistant message. The result's
-- content is one of:
--   advisor_result            { text, stop_reason? }  readable guidance
--   advisor_redacted_result   { encrypted_content, stop_reason? }
--   advisor_tool_result_error { error_code }
-- stop_reason "refusal" on either result type means the advisor declined;
-- an advisor_result's text is then the reason. Shapes follow the 2.1.321
-- CLI's renderer; fixtures live in tests/fixtures/ndjson/advisor_*.ndjson.
--
-- Callers turn the call into an ordinary tool_use block named "advisor" so
-- it shares tool headers, timers, grouping and subagent nesting, then hand
-- the result content to classify().

local M = {}

M.TOOL_NAME = 'advisor'

--- Whether a content block is an advisor call.
---@param block table?
---@return boolean
function M.is_call(block)
  return type(block) == 'table' and block.type == 'server_tool_use' and block.name == M.TOOL_NAME
end

--- The advisor call as a tool_use block. The input is always empty, so it is
--- dropped: the tool fold holds only the result.
---@param block table server_tool_use block
---@return table
function M.as_tool_use(block)
  return { type = 'tool_use', id = block.id, name = M.TOOL_NAME }
end

---@param v any
---@return string?
local function str(v)
  if type(v) == 'string' and v ~= '' then return v end
  return nil
end

---@class cc.AdvisorOutcome
---@field status 'reviewed'|'redacted'|'declined'|'unavailable'|'unknown'
---@field summary string? header text after the tool name
---@field text string? body shown in the fold, if any
---@field label string? body fold label
---@field is_error boolean

--- Classify an advisor_tool_result's content.
---@param content table?
---@return cc.AdvisorOutcome
function M.classify(content)
  local cfg = require('cc.config').options.advisor or {}
  if type(content) ~= 'table' then
    return { status = 'unknown', is_error = false }
  end
  local kind = content.type
  local readable = kind == 'advisor_result'
  if (readable or kind == 'advisor_redacted_result') and content.stop_reason == 'refusal' then
    -- Checked before the type: a declined advisor_result carries its reason
    -- as text and must not render as guidance.
    local reason = readable and str(content.text) or nil
    return {
      status = 'declined',
      summary = cfg.declined,
      text = reason,
      label = cfg.reason_label,
      is_error = false,
    }
  end
  if readable then
    return {
      status = 'reviewed',
      summary = cfg.reviewed,
      text = str(content.text),
      label = cfg.guidance_label,
      is_error = false,
    }
  end
  if kind == 'advisor_redacted_result' then
    return { status = 'redacted', summary = cfg.redacted, is_error = false }
  end
  if kind == 'advisor_tool_result_error' then
    local code = str(content.error_code) or 'unknown'
    local summary = (cfg.unavailable or ''):gsub('%${error_code}', function() return code end)
    return { status = 'unavailable', summary = summary, is_error = true }
  end
  return { status = 'unknown', is_error = false }
end

return M
