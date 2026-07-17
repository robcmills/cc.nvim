#!/usr/bin/env -S nvim -l
-- Fake codex app-server: minimal JSON-RPC responder for integration tests.
-- Spawned via fake_codex.sh in place of `codex app-server`.
--
-- Behavior:
--   - initialize        → success response
--   - thread/start      → canned thread
--   - thread/resume     → canned thread with one stored turn
--   - turn/start        → canned streamed turn (agentMessage + commandExecution
--                         + tokenUsage + turn/completed)
--   - turn/interrupt    → success + turn/completed(status=interrupted)
--   - thread/name/set   → success
--   - anything else with an id → empty success
--   - exits when stdin closes

local function writeln(obj)
  io.write(vim.json.encode(obj) .. '\n')
  io.flush()
end

local THREAD = {
  id = 'thread-1',
  sessionId = 'thread-1',
  preview = '',
  name = vim.NIL,
  cwd = '/tmp',
  ephemeral = false,
  createdAt = 1700000000,
  updatedAt = 1700000000,
  status = { type = 'idle' },
  modelProvider = 'openai',
  cliVersion = '0.0.0-fake',
  source = 'fake',
  turns = {},
}

local function thread_response(id, turns)
  local thread = vim.deepcopy(THREAD)
  thread.turns = turns or {}
  writeln({
    id = id,
    result = {
      thread = thread,
      model = 'gpt-test',
      modelProvider = 'openai',
      approvalPolicy = 'never',
      approvalsReviewer = 'user',
      sandbox = { type = 'workspaceWrite' },
      reasoningEffort = 'medium',
      cwd = '/tmp',
    },
  })
end

local function usage(input, cached, output)
  local b = {
    totalTokens = input + output,
    inputTokens = input,
    cachedInputTokens = cached,
    outputTokens = output,
    reasoningOutputTokens = 0,
  }
  return { total = b, last = b, modelContextWindow = 200000 }
end

local function play_turn()
  local T = { threadId = 'thread-1', turnId = 'turn-1' }
  writeln({ method = 'turn/started', params = {
    threadId = 'thread-1',
    turn = { id = 'turn-1', items = {}, status = 'inProgress' },
  } })
  writeln({ method = 'item/started', params = {
    threadId = T.threadId, turnId = T.turnId, startedAtMs = 0,
    item = { type = 'agentMessage', id = 'msg-1', text = '' },
  } })
  writeln({ method = 'item/agentMessage/delta', params = {
    threadId = T.threadId, turnId = T.turnId, itemId = 'msg-1',
    delta = 'hello from fake codex',
  } })
  writeln({ method = 'item/completed', params = {
    threadId = T.threadId, turnId = T.turnId, completedAtMs = 1,
    item = { type = 'agentMessage', id = 'msg-1', text = 'hello from fake codex' },
  } })
  writeln({ method = 'item/started', params = {
    threadId = T.threadId, turnId = T.turnId, startedAtMs = 2,
    item = { type = 'commandExecution', id = 'cmd-1', command = 'echo fake',
      cwd = '/tmp', status = 'inProgress' },
  } })
  writeln({ method = 'item/completed', params = {
    threadId = T.threadId, turnId = T.turnId, completedAtMs = 3,
    item = { type = 'commandExecution', id = 'cmd-1', command = 'echo fake',
      cwd = '/tmp', status = 'completed', exitCode = 0, durationMs = 5,
      aggregatedOutput = 'fake\n' },
  } })
  writeln({ method = 'thread/tokenUsage/updated', params = {
    threadId = T.threadId, turnId = T.turnId, tokenUsage = usage(100, 40, 10),
  } })
  writeln({ method = 'turn/completed', params = {
    threadId = 'thread-1',
    turn = { id = 'turn-1', items = {}, status = 'completed', durationMs = 1234 },
  } })
end

local STORED_TURN = {
  id = 'turn-0',
  status = 'completed',
  items = {
    { type = 'userMessage', id = 'u-0',
      content = { { type = 'text', text = 'stored prompt' } } },
    { type = 'agentMessage', id = 'a-0', text = 'stored reply' },
  },
}

while true do
  local line = io.read('*l')
  if not line then break end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(msg) == 'table' and msg.method then
    local method, id = msg.method, msg.id
    if method == 'initialize' then
      writeln({ id = id, result = {
        userAgent = 'fake-codex', codexHome = '/tmp',
        platformFamily = 'unix', platformOs = 'test',
      } })
    elseif method == 'thread/start' then
      thread_response(id, {})
    elseif method == 'thread/resume' then
      thread_response(id, { STORED_TURN })
    elseif method == 'turn/start' then
      writeln({ id = id, result = {
        turn = { id = 'turn-1', items = {}, status = 'inProgress' },
      } })
      play_turn()
    elseif method == 'turn/interrupt' then
      writeln({ id = id, result = vim.empty_dict() })
      writeln({ method = 'turn/completed', params = {
        threadId = 'thread-1',
        turn = { id = 'turn-1', items = {}, status = 'interrupted' },
      } })
    elseif id ~= nil then
      writeln({ id = id, result = vim.empty_dict() })
    end
  end
end
