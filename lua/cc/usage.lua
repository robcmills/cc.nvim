-- Token usage parsing + formatting. One canonical shape, used by every
-- renderer and tracker in the plugin.
--
-- Two CLI surfaces emit usage with different semantics; both arrive here:
--   * NDJSON `message_start.message.usage` — per-API-call. cache_read +
--     cache_creation + input is the live prompt size sent to the API.
--   * NDJSON `result.usage` — `QueryEngine.totalUsage`, accumulated across
--     every API call in the process lifetime (never reset). To derive a
--     per-result delta, subtract the previous `result.usage`.
--   * JSONL `message.usage` (transcript records) — per-API-call, like
--     message_start. Accumulating these gives the conversation's total.
--
-- This module only normalizes a single usage table; the caller decides
-- replace vs. accumulate vs. delta based on its source. See session.lua
-- for the delta tracker.

local M = {}

---@class cc.Usage
---@field input integer
---@field output integer
---@field cache_creation integer
---@field cache_read integer
---@field context_size integer input + cache_creation + cache_read — size of the API request prompt
---@field total integer input + output — billing-style total, matches Claude Code's getTotalInputTokens + getTotalOutputTokens

---@type cc.Usage
M.ZERO = { input = 0, output = 0, cache_creation = 0, cache_read = 0, context_size = 0, total = 0 }

--- Normalize an Anthropic API–shaped usage table into the canonical struct.
--- Missing fields default to 0. Non-table input returns the zero struct
--- (caller-friendly: never have to nil-check).
---@param u table?
---@return cc.Usage
function M.normalize(u)
  if type(u) ~= 'table' then
    return { input = 0, output = 0, cache_creation = 0, cache_read = 0, context_size = 0, total = 0 }
  end
  local input = u.input_tokens or 0
  local output = u.output_tokens or 0
  local cache_creation = u.cache_creation_input_tokens or 0
  local cache_read = u.cache_read_input_tokens or 0
  return {
    input = input,
    output = output,
    cache_creation = cache_creation,
    cache_read = cache_read,
    context_size = input + cache_creation + cache_read,
    total = input + output,
  }
end

--- Compact token count: >=1000 → "1.5k" (trailing ".0" stripped), else the
--- integer. Empty string for nil / non-positive.
---@param n number?
---@return string
function M.fmt_compact(n)
  if type(n) ~= 'number' or n <= 0 then return '' end
  if n >= 1000 then
    return (string.format('%.1fk', n / 1000):gsub('%.0k$', 'k'))
  end
  return tostring(math.floor(n))
end

return M
