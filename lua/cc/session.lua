-- Conversation state: tracks session_id, turns, and streaming content blocks.
-- The router feeds stream events here; output.lua reads from here to render.

local Usage = require('cc.usage')

local M = {}

---@class cc.Session
---@field id string?
---@field model string?
---@field tools table
---@field permission_mode string?
---@field resolved_effort string? the CLI's resolved effort level (applied.effort from get_settings); lets the statusline show what 'auto' resolves to
---@field turns table[]
---@field current_message table?
---@field current_blocks table<integer, table>
---@field is_streaming boolean
---@field turn_active boolean true from user submit through the final result
---@field turn_started_at integer? ms timestamp from vim.uv.now() while turn_active
---@field interrupt_pending boolean
---@field cost_usd number
---@field input_tokens integer cumulative fresh-input tokens for this conversation (across engine restarts / resume)
---@field output_tokens integer cumulative output tokens for this conversation
---@field cache_creation_input_tokens integer cumulative cache-write tokens
---@field cache_read_input_tokens integer cumulative cache-read tokens
---@field context_tokens integer last API call's full input load (input + cache_creation + cache_read); approximates current context window usage
---@field context_window integer? authoritative context window for self.model, taken from result.modelUsage when the CLI provides it
---@field last_result_usage cc.Usage? snapshot of the previous result.usage (cumulative within the current engine) — diffed against the next result to derive the per-result delta we add to the cumulative session totals
local Session = {}
Session.__index = Session

---@return integer
local function now_ms()
  return (vim.uv or vim.loop).now()
end

function M.new()
  return setmetatable({
    id = nil,
    model = nil,
    tools = {},
    permission_mode = nil,
    resolved_effort = nil,
    turns = {},
    current_message = nil,
    current_blocks = {},
    is_streaming = false,
    turn_active = false,
    turn_started_at = nil,
    interrupt_pending = false,
    cost_usd = 0,
    input_tokens = 0,
    output_tokens = 0,
    cache_creation_input_tokens = 0,
    cache_read_input_tokens = 0,
    context_tokens = 0,
    context_window = nil,
    last_result_usage = nil,
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
  self.skills = msg.skills or self.skills
  -- A fresh engine starts its totalUsage at zero. Wipe the diff baseline so
  -- the next result.usage delta is the full new-engine contribution. The
  -- session-cumulative input/output/cache_* fields are preserved (they may
  -- already be seeded from a JSONL resume).
  self.last_result_usage = nil
end

---@param text string
function Session:add_user_turn(text)
  self.interrupt_pending = false
  self.turn_active = true
  self.turn_started_at = now_ms()
  table.insert(self.turns, {
    role = 'user',
    text = text,
  })
end

---@param message table anthropic message object
function Session:begin_message(message)
  -- An autonomous turn (e.g., agent wake-up via ScheduleWakeup) arrives as a
  -- message_start without a preceding user submit. Flip turn_active on so
  -- interrupt, submit-guards, and statusline see the live turn.
  self.turn_active = true
  if not self.turn_started_at then
    self.turn_started_at = now_ms()
  end
  self.is_streaming = true
  self.current_message = {
    id = message and message.id or nil,
    role = message and message.role or 'assistant',
    blocks = {},
  }
  self.current_blocks = {}
  -- Snapshot the current context size from THIS message's usage. One
  -- message_start = one API call, so context_size = input + cache_creation +
  -- cache_read is the genuine prompt size sent to the API. Do not source
  -- this from result.usage — `result` carries QueryEngine.totalUsage,
  -- accumulated across every API call in the engine lifetime; for a
  -- multi-tool turn that's many multiples of the actual context size.
  if message and type(message.usage) == 'table' then
    self.context_tokens = Usage.normalize(message.usage).context_size
  end
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

--- Finish the active turn and return provider-neutral timing metadata for its
--- end-of-turn stamp.
---@param elapsed_ms integer? authoritative provider-reported duration
---@return { turn_ended_at: integer, turn_elapsed_ms: integer? }
function Session:finish_turn(elapsed_ms)
  self.interrupt_pending = false
  self.turn_active = false
  self.is_streaming = false

  local result = { turn_ended_at = os.time() }
  if type(elapsed_ms) == 'number' then
    result.turn_elapsed_ms = elapsed_ms
  elseif self.turn_started_at then
    result.turn_elapsed_ms = now_ms() - self.turn_started_at
  end
  self.turn_started_at = nil
  return result
end

---@param msg table result message
---@param already_finished boolean? true when an interrupt acknowledgement
--- already ended and stamped this turn; the trailing result is state-only
function Session:on_result(msg, already_finished)
  if not already_finished then
    local timing = self:finish_turn()
    msg.turn_ended_at = timing.turn_ended_at
    msg.turn_elapsed_ms = timing.turn_elapsed_ms
  end
  if msg.total_cost_usd then
    self.cost_usd = msg.total_cost_usd
  end
  if msg.usage then
    -- msg.usage IS QueryEngine.totalUsage — cumulative-since-engine-start,
    -- never reset within the process (services/api/claude.ts accumulateUsage
    -- at every message_stop). To extract this result's contribution we diff
    -- against the previous snapshot. On a fresh engine the snapshot is nil
    -- (on_init wipes it), so the first delta equals the new engine's full
    -- contribution — which composes correctly when resume has seeded the
    -- cumulative session totals from JSONL history.
    local current = Usage.normalize(msg.usage)
    local last = self.last_result_usage or Usage.ZERO
    -- Guard against negative deltas. Shouldn't happen (totalUsage is
    -- monotonic), but if it does — engine-side bug, fixture surprise —
    -- clamp to 0 rather than drag the cumulative backwards.
    local function delta(a, b) return a > b and (a - b) or 0 end
    self.input_tokens = self.input_tokens + delta(current.input, last.input)
    self.output_tokens = self.output_tokens + delta(current.output, last.output)
    self.cache_creation_input_tokens = self.cache_creation_input_tokens
      + delta(current.cache_creation, last.cache_creation)
    self.cache_read_input_tokens = self.cache_read_input_tokens
      + delta(current.cache_read, last.cache_read)
    self.last_result_usage = current
  end
  -- The CLI's `result.modelUsage` is keyed by model name and carries the
  -- authoritative contextWindow it resolved via env override → [1m] suffix →
  -- model capability table → 1M-beta header → ant-only registry → 200K. Far
  -- more reliable than our suffix-parse fallback, which can't see the beta
  -- header or capability table. Subagents may add other model entries; we
  -- only care about the current session's model.
  if type(msg.modelUsage) == 'table' and self.model then
    local mu = msg.modelUsage[self.model]
    if type(mu) == 'table' and type(mu.contextWindow) == 'number' and mu.contextWindow > 0 then
      self.context_window = mu.contextWindow
    end
  end
end

return M
