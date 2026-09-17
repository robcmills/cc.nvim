local M = {}

---@class cc.LimitReading
---@field ts string? UTC timestamp, set when appended
---@field provider 'claude'|'codex'
---@field window string
---@field used_pct number?
---@field resets_at number?
---@field status string?
---@field plan string?

local last_written = {}
local warned = false

--- Omit JSON null fields even when called with a default vim.json.decode.
local function optional(value)
  if value ~= vim.NIL then return value end
end

---@param info table
---@return cc.LimitReading[]
function M.from_claude(info)
  local readings = {}
  local named = optional(info.rateLimitType)
  -- `status` describes the `rateLimitType` window only; other windows in
  -- `unifiedWindows` carry no status of their own.
  local function add(window, data, status)
    local utilization = optional(data.utilization)
    table.insert(readings, {
      provider = 'claude',
      window = window,
      used_pct = utilization and math.floor(utilization * 100 + 0.5) or nil,
      resets_at = optional(data.resetsAt),
      status = status,
    })
  end
  if type(info.unifiedWindows) == 'table' then
    for window, data in pairs(info.unifiedWindows) do
      if type(data) == 'table' then
        add(window, data, window == named and optional(info.status) or nil)
      end
    end
  else
    add(named or 'unknown', info, optional(info.status))
  end
  return readings
end

---@param snapshot table
---@return cc.LimitReading[]
function M.from_codex(snapshot)
  local readings = {}
  for _, name in ipairs({ 'primary', 'secondary' }) do
    local data = snapshot[name]
    if type(data) == 'table' then
      local mins = optional(data.windowDurationMins)
      local window = mins == 300 and 'five_hour' or mins == 10080 and 'seven_day'
        or (mins and tostring(mins) .. 'm' or 'unknown')
      table.insert(readings, {
        provider = 'codex',
        window = window,
        used_pct = optional(data.usedPercent),
        resets_at = optional(data.resetsAt),
        status = optional(snapshot.rateLimitReachedType) or 'allowed',
        plan = optional(snapshot.planType),
      })
    end
  end
  return readings
end

---@param readings cc.LimitReading[]
function M.append(readings)
  local path = require('cc.config').options.limits_log
  if not path or path == '' then return end
  local file
  for _, reading in ipairs(readings) do
    local key = reading.provider .. '|' .. reading.window
    local value = table.concat({
      tostring(reading.used_pct), tostring(reading.resets_at), tostring(reading.status),
    }, '|')
    if last_written[key] ~= value then
      if not file then
        path = vim.fn.expand(path)
        -- Let io.open report failure even if the parent cannot be created.
        pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ':h'), 'p')
        local err
        file, err = io.open(path, 'a')
        if not file then
          if not warned then
            warned = true
            vim.notify('cc.nvim: cannot open limits_log: ' .. tostring(err), vim.log.levels.WARN)
          end
          return
        end
      end
      reading.ts = os.date('!%Y-%m-%dT%H:%M:%S+00:00')
      if file:write(vim.json.encode(reading), '\n') then last_written[key] = value end
    end
  end
  if file then file:close() end
end

---@param info any
function M.record_claude(info)
  if type(info) ~= 'table' then return end
  M.append(M.from_claude(info))
end

---@param snapshot any
function M.record_codex(snapshot)
  if type(snapshot) ~= 'table' then return end
  M.append(M.from_codex(snapshot))
end

--- Reset logging state for tests.
function M._reset()
  last_written = {}
  warned = false
end

return M
