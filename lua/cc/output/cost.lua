-- Per-turn result/cost line formatting. Pure functions — no buffer state.

local M = {}

--- Compact token count: >=1000 → "7.7k" (trailing ".0" stripped), else raw int.
function M.fmt_cache_tokens(n)
  if n >= 1000 then
    return (string.format('%.1fk', n / 1000):gsub('%.0k$', 'k'))
  end
  return tostring(n)
end

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
  if result.usage then
    local u = result.usage
    if u.input_tokens then
      table.insert(parts, string.format('%d in', u.input_tokens))
    end
    if u.output_tokens then
      table.insert(parts, string.format('%d out', u.output_tokens))
    end
    if u.cache_read_input_tokens and u.cache_read_input_tokens > 0 then
      table.insert(parts, M.fmt_cache_tokens(u.cache_read_input_tokens) .. ' cache read')
    end
    if u.cache_creation_input_tokens and u.cache_creation_input_tokens > 0 then
      table.insert(parts, M.fmt_cache_tokens(u.cache_creation_input_tokens) .. ' cache write')
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ' │ ')
end

return M
