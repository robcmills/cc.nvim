-- Per-turn result/cost line formatting. Pure functions — no buffer state.

local Usage = require('cc.usage')

local M = {}

-- Back-compat: `fmt_cache_tokens` was the prior public helper. Forward to
-- the shared formatter so any downstream user format hooks still work.
M.fmt_cache_tokens = Usage.fmt_compact

---@param ms integer
---@return string
function M.fmt_duration(ms)
  local total_s = math.max(0, math.floor(ms / 1000))
  if total_s < 60 then return string.format('%ds', total_s) end
  local minutes = math.floor(total_s / 60)
  local seconds = total_s % 60
  if minutes < 60 then return string.format('%dm %ds', minutes, seconds) end
  local hours = math.floor(minutes / 60)
  minutes = minutes % 60
  return string.format('%dh %dm', hours, minutes)
end

--- Default formatter for the per-turn result line. Returns the inner text
--- (without the leading/trailing "──" separators) or nil if nothing to show.
---@param result table
---@return string?
function M.default_format(result)
  local parts = {}
  if type(result.turn_elapsed_ms) == 'number' then
    table.insert(parts, M.fmt_duration(result.turn_elapsed_ms))
  end
  if result.total_cost_usd then
    table.insert(parts, string.format('$%.4f', result.total_cost_usd))
  end
  local u = Usage.normalize(result.usage)
  if u.input > 0 then table.insert(parts, string.format('%d in', u.input)) end
  if u.output > 0 then table.insert(parts, string.format('%d out', u.output)) end
  if u.cache_read > 0 then
    table.insert(parts, Usage.fmt_compact(u.cache_read) .. ' cache read')
  end
  if u.cache_creation > 0 then
    table.insert(parts, Usage.fmt_compact(u.cache_creation) .. ' cache write')
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ' │ ')
end

return M
