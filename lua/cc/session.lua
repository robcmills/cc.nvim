-- Conversation state: tracks session_id, turns, and streaming content blocks.
-- The router feeds stream events here; output.lua reads from here to render.

local M = {}

---@class cc.Session
---@field id string?
---@field model string?
---@field tools table
---@field permission_mode string?
---@field turns table[]
---@field current_message table?
---@field current_blocks table<integer, table>
---@field is_streaming boolean
---@field turn_active boolean true from user submit through the final result
---@field interrupt_pending boolean
---@field cost_usd number
---@field input_tokens integer
---@field output_tokens integer
local Session = {}
Session.__index = Session

function M.new()
  return setmetatable({
    id = nil,
    model = nil,
    tools = {},
    permission_mode = nil,
    turns = {},
    current_message = nil,
    current_blocks = {},
    is_streaming = false,
    turn_active = false,
    interrupt_pending = false,
    cost_usd = 0,
    input_tokens = 0,
    output_tokens = 0,
    -- tool_use_id -> { name, input, result, is_error, start_time }
    tool_calls = {},
  }, Session)
end

--- Record a tool_use block when it begins streaming.
---@param tool_use_id string
---@param name string
function Session:begin_tool_call(tool_use_id, name)
  if not tool_use_id then return end
  self.tool_calls[tool_use_id] = {
    name = name,
    input = nil,
    result = nil,
    is_error = false,
    start_time = vim.uv and vim.uv.now() or vim.loop.now(),
  }
end

--- Update a tool_use block's input after content_block_stop.
---@param tool_use_id string
---@param input table?
function Session:finalize_tool_call(tool_use_id, input)
  local t = self.tool_calls[tool_use_id]
  if t then t.input = input end
end

--- Record a tool_result.
---@param tool_use_id string
---@param content string|table
---@param is_error boolean?
function Session:record_tool_result(tool_use_id, content, is_error)
  local t = self.tool_calls[tool_use_id]
  if not t then
    self.tool_calls[tool_use_id] = { result = content, is_error = is_error }
    return
  end
  t.result = content
  t.is_error = is_error or false
end

---@param msg table system/init message
function Session:on_init(msg)
  self.id = msg.session_id or self.id
  self.model = msg.model or self.model
  self.tools = msg.tools or self.tools
  self.permission_mode = msg.permissionMode or self.permission_mode
  self.slash_commands = msg.slash_commands or self.slash_commands
end

---@param text string
function Session:add_user_turn(text)
  self.interrupt_pending = false
  self.turn_active = true
  table.insert(self.turns, {
    role = 'user',
    text = text,
  })
end

---@param message table anthropic message object
function Session:begin_message(message)
  self.is_streaming = true
  self.current_message = {
    id = message and message.id or nil,
    role = message and message.role or 'assistant',
    blocks = {},
  }
  self.current_blocks = {}
end

---@param index integer
---@param content_block table
function Session:begin_block(index, content_block)
  local block = {
    type = content_block.type,
    text = content_block.text or '',
    thinking = content_block.thinking or '',
    id = content_block.id,
    name = content_block.name,
    input = content_block.input,
    input_json = '',
  }
  self.current_blocks[index] = block
end

---@param index integer
---@param delta table
---@return string? kind 'text' | 'thinking' | 'input_json' | nil
---@return string? chunk
function Session:apply_delta(index, delta)
  local block = self.current_blocks[index]
  if not block then
    return nil, nil
  end
  if delta.type == 'text_delta' and delta.text then
    block.text = block.text .. delta.text
    return 'text', delta.text
  elseif delta.type == 'thinking_delta' and delta.thinking then
    block.thinking = block.thinking .. delta.thinking
    return 'thinking', delta.thinking
  elseif delta.type == 'input_json_delta' and delta.partial_json then
    block.input_json = block.input_json .. delta.partial_json
    return 'input_json', delta.partial_json
  end
  return nil, nil
end

---@param index integer
function Session:end_block(index)
  local block = self.current_blocks[index]
  if not block then
    return
  end
  if block.type == 'tool_use' and block.input_json ~= '' then
    local ok, parsed = pcall(vim.json.decode, block.input_json)
    if ok then
      block.input = parsed
    end
  end
  if self.current_message then
    self.current_message.blocks[index + 1] = block -- 1-based for Lua
  end
end

function Session:end_message()
  if self.current_message then
    -- Compact blocks into a dense array (stream indices may be sparse)
    local dense = {}
    for _, b in pairs(self.current_message.blocks) do
      table.insert(dense, b)
    end
    self.current_message.blocks = dense
    table.insert(self.turns, {
      role = 'assistant',
      message = self.current_message,
    })
    self.current_message = nil
    self.current_blocks = {}
  end
  self.is_streaming = false
end

---@param msg table result message
function Session:on_result(msg)
  self.interrupt_pending = false
  self.turn_active = false
  if msg.total_cost_usd then
    self.cost_usd = msg.total_cost_usd
  end
  if msg.usage then
    local u = msg.usage
    -- Match Claude Code's getTotalInputTokens/getTotalOutputTokens: accumulate
    -- fresh input + output only. Cache reads/creations are billed separately
    -- and would dwarf the real conversation size if folded in here.
    self.input_tokens = self.input_tokens + (u.input_tokens or 0)
    self.output_tokens = self.output_tokens + (u.output_tokens or 0)
  end
  self.is_streaming = false
end

return M
