-- Notice text for the CLI's error-shaped messages: `rate_limit_event`,
-- synthetic API-error `assistant` messages, and error `result`s. Pure
-- functions — no buffer state — so the wording is unit-testable and the
-- router only decides *when* to render.

local M = {}

local LIMIT_LABELS = {
  five_hour = '5-hour',
  seven_day = '7-day',
  seven_day_opus = '7-day Opus',
  seven_day_sonnet = '7-day Sonnet',
  overage = 'extra usage',
}

local RESULT_SUBTYPE_LABELS = {
  error_during_execution = 'error during execution',
  error_max_turns = 'max turns reached',
  error_max_budget_usd = 'max budget reached',
  error_max_structured_output_retries = 'max structured output retries reached',
}

-- The CLI records a rate-limited call it silently recovered from (e.g. model
-- fallback) as an error message with this text. Nothing to show the user.
M.NO_RESPONSE_REQUESTED = 'No response requested.'

--- Collapse a possibly multi-line message into one notice-safe line.
---@param text string
---@return string
function M.one_line(text)
  return (text:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
end

--- Local wall-clock time for a reset epoch. The CLI reports seconds, but
--- tolerate milliseconds in case that changes.
---@param t number
---@return string
function M.fmt_reset(t)
  if t > 1e12 then t = t / 1000 end
  local now = os.time()
  local same_day = os.date('%Y-%m-%d', t) == os.date('%Y-%m-%d', now)
  return os.date(same_day and '%H:%M' or '%Y-%m-%d %H:%M', math.floor(t))
end

--- Notice for a `rate_limit_event`, or nil when there is nothing worth
--- saying. `prev_status` is the status of the last event rendered so a
--- return to `allowed` reads as "lifted" only after a warning/rejection.
---@param info table? SDKRateLimitInfo
---@param prev_status string?
---@return string?
function M.format_rate_limit(info, prev_status)
  if type(info) ~= 'table' then return nil end
  local status = info.status
  local head
  if status == 'rejected' then
    head = 'Usage limit reached'
  elseif status == 'allowed_warning' then
    head = 'Approaching usage limit'
  elseif status == 'allowed' then
    if prev_status == 'rejected' or prev_status == 'allowed_warning' then
      return 'Usage limit lifted'
    end
    return nil
  else
    return nil
  end

  local label = LIMIT_LABELS[info.rateLimitType]
  if label then head = head .. ' (' .. label .. ')' end
  local parts = { head }
  if status == 'allowed_warning' and type(info.utilization) == 'number' then
    table.insert(parts, string.format('%d%% used', math.floor(info.utilization * 100 + 0.5)))
  end
  if type(info.resetsAt) == 'number' then
    table.insert(parts, 'resets ' .. M.fmt_reset(info.resetsAt))
  end
  if info.isUsingOverage == true then
    table.insert(parts, 'using extra usage')
  end
  return table.concat(parts, ' · ')
end

--- Prefix with "Error: " unless the text already announces itself as one
--- (the CLI's synthetic messages start with "API Error: ...").
---@param text string
---@return string
function M.label(text)
  if text:match('^[%w ]*Error:') then return text end
  return 'Error: ' .. text
end

--- Text of a synthetic API-error `assistant` message, or nil if there is
--- nothing to show.
---@param msg table SDKAssistantMessage with `error` set
---@return string?
function M.format_assistant_error(msg)
  local message = msg.message
  local content = message and message.content
  local parts = {}
  if type(content) == 'string' then
    table.insert(parts, content)
  elseif type(content) == 'table' then
    for _, block in ipairs(content) do
      if type(block) == 'table' and block.type == 'text' and type(block.text) == 'string' then
        table.insert(parts, block.text)
      end
    end
  end
  local text = M.one_line(table.concat(parts, ' '))
  if text == '' or text == M.NO_RESPONSE_REQUESTED then
    if type(msg.error) == 'string' then
      return M.label(msg.error:gsub('_', ' '))
    end
    return nil
  end
  return M.label(text)
end

--- Text of an error `result`, or nil when the result is not an error.
---@param result table SDKResultMessage
---@return string?
function M.format_result_error(result)
  if result.is_error ~= true then return nil end
  local text
  if type(result.errors) == 'table' and type(result.errors[1]) == 'string' then
    text = result.errors[1]
  elseif type(result.result) == 'string' and result.result ~= '' then
    text = result.result
  elseif type(result.subtype) == 'string' and result.subtype ~= 'success' then
    text = RESULT_SUBTYPE_LABELS[result.subtype] or result.subtype
  else
    text = 'turn failed'
  end
  return M.label(M.one_line(text))
end

return M
