-- NDJSON line parser: accumulates raw byte chunks into complete lines,
-- decodes each as JSON. Handles partial lines across chunks.

local M = {}

---@class cc.Parser
---@field buffer string
local Parser = {}
Parser.__index = Parser

function M.new()
  return setmetatable({ buffer = '' }, Parser)
end

--- Feed raw bytes (possibly containing partial or multiple lines).
--- Returns a list of decoded JSON messages.
---@param data string
---@return table[]
function Parser:feed(data)
  if not data or data == '' then
    return {}
  end
  self.buffer = self.buffer .. data
  local messages = {}
  while true do
    local nl = self.buffer:find('\n', 1, true)
    if not nl then
      break
    end
    local line = self.buffer:sub(1, nl - 1)
    self.buffer = self.buffer:sub(nl + 1)
    if line ~= '' then
      local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(msg) == 'table' then
        table.insert(messages, msg)
      else
        -- Surface decode errors but don't crash the stream
        vim.schedule(function()
          vim.notify('cc.nvim: failed to decode NDJSON line: ' .. tostring(msg), vim.log.levels.WARN)
        end)
      end
    end
  end
  return messages
end

--- Reset buffer (e.g. after process exit).
function Parser:reset()
  self.buffer = ''
end

return M
