-- Codex provider: JSON-RPC handshake, request correlation, item → render
-- translation, usage mapping, approvals, and interruption. The transport is
-- stubbed (_write_line collects encoded lines; server messages are fed via
-- _on_message), so these tests cover the full protocol layer without
-- spawning codex.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Build a codex provider with a stubbed transport in the child.
--- _G._test_sent collects decoded JSON-RPC messages written by the client.
--- _G._feed(msg) delivers a decoded server message.
local function setup_codex(child, config_opts)
  child.lua(string.format([==[
    require('cc.config').setup(%s)
    local Session = require('cc.session')
    local Output = require('cc.output')
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local inst = { session = session, output = output }
    local session_ids = {}
    local provider = require('cc.providers.codex').attach({
      instance = inst,
      session = session,
      output = output,
      on_session_id = function(id) table.insert(session_ids, id) end,
    })
    inst.provider = provider
    inst.process = provider

    local sent = {}
    provider.alive = true
    provider._write_line = function(self, line)
      table.insert(sent, vim.json.decode(line, { luanil = { object = true, array = true } }))
    end

    _G._test_bufnr = bufnr
    _G._test_session = session
    _G._test_output = output
    _G._test_inst = inst
    _G._test_provider = provider
    _G._test_sent = sent
    _G._test_session_ids = session_ids
    _G._feed = function(msg) provider:_on_message(msg) end
  ]==], config_opts or '{ provider = "codex" }'))
end

--- Drive the handshake through thread/start so the provider is ready.
local function handshake(child)
  child.lua([==[
    _G._test_provider:_start_protocol()
    -- initialize response (id matches the first request sent)
    _G._feed({ id = _G._test_sent[1].id, result = { userAgent = 'fake' } })
    -- thread/start response
    local start_req
    for _, m in ipairs(_G._test_sent) do
      if m.method == 'thread/start' then start_req = m end
    end
    _G._feed({ id = start_req.id, result = {
      thread = { id = 'thread-1', preview = '', turns = {} },
      model = 'gpt-test',
      modelProvider = 'openai',
      approvalPolicy = 'never',
      approvalsReviewer = 'user',
      sandbox = { type = 'workspaceWrite' },
      reasoningEffort = 'medium',
      cwd = '/tmp',
    } })
  ]==])
end

local function buffer_text(child)
  return table.concat(
    child.lua_get('vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false)'), '\n')
end

--- Find the first sent message with the given method.
local function sent_with_method(child, method)
  return child.lua_get(string.format([==[
    (function()
      for _, m in ipairs(_G._test_sent) do
        if m.method == %q then return m end
      end
      return nil
    end)()
  ]==], method))
end

T['handshake'] = MiniTest.new_set()

T['handshake']['initialize → initialized → thread/start'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[1].method, 'initialize')
  eq(sent[1].params.clientInfo.name, 'cc.nvim')
  eq(sent[2].method, 'initialized')
  eq(sent[2].id, nil) -- notification, not a request
  eq(sent[3].method, 'thread/start')
  eq(type(sent[3].id), 'number')
end

T['handshake']['thread/start response seeds session state'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  eq(_G.child.lua_get('_G._test_session.id'), 'thread-1')
  eq(_G.child.lua_get('_G._test_session.model'), 'gpt-test')
  eq(_G.child.lua_get('_G._test_session.permission_mode'), 'never/workspaceWrite')
  eq(_G.child.lua_get('_G._test_session.resolved_effort'), 'medium')
  eq(_G.child.lua_get('_G._test_session_ids'), { 'thread-1' })
end

T['handshake']['approval_policy and sandbox config forwarded'] = function()
  setup_codex(_G.child, [[{
    provider = 'codex',
    providers = { codex = { approval_policy = 'on-request', sandbox = 'read-only' } },
  }]])
  _G.child.lua([[
    _G._test_provider:_start_protocol()
    _G._feed({ id = _G._test_sent[1].id, result = {} })
  ]])
  local req = sent_with_method(_G.child, 'thread/start')
  eq(req.params.approvalPolicy, 'on-request')
  eq(req.params.sandbox, 'read-only')
end

T['handshake']['resume path calls thread/resume and replays turns'] = function()
  setup_codex(_G.child, [[{
    provider = 'codex',
    providers = { codex = {
      approval_policy = 'on-request',
      sandbox = 'danger-full-access',
    } },
  }]])
  _G.child.lua([==[
    _G._test_provider.resume_id = 'thread-9'
    _G._test_provider:_start_protocol()
    _G._feed({ id = _G._test_sent[1].id, result = {} })
    local req
    for _, m in ipairs(_G._test_sent) do
      if m.method == 'thread/resume' then req = m end
    end
    _G._test_resume_req = req
    _G._feed({ id = req.id, result = {
      thread = {
        id = 'thread-9',
        turns = { {
          id = 'turn-0', status = 'completed',
          items = {
            { type = 'userMessage', id = 'u0',
              content = { { type = 'text', text = 'stored prompt' } } },
            { type = 'agentMessage', id = 'a0', text = 'stored reply' },
            { type = 'commandExecution', id = 'c0', command = 'ls',
              status = 'completed', exitCode = 0, aggregatedOutput = 'file.txt\n' },
          },
        } },
      },
      model = 'gpt-test', approvalPolicy = 'never',
      sandbox = { type = 'workspaceWrite' },
    } })
  ]==])
  eq(_G.child.lua_get('_G._test_resume_req.params.threadId'), 'thread-9')
  eq(_G.child.lua_get('_G._test_resume_req.params.approvalPolicy'), 'on-request')
  eq(_G.child.lua_get('_G._test_resume_req.params.sandbox'), 'danger-full-access')
  local text = buffer_text(_G.child)
  eq(text:find('User:', 1, true) ~= nil, true)
  eq(text:find('stored prompt', 1, true) ~= nil, true)
  eq(text:find('stored reply', 1, true) ~= nil, true)
  eq(text:find('Bash: ls', 1, true) ~= nil, true)
  eq(text:find('file.txt', 1, true) ~= nil, true)
  eq(text:find('resumed thread%-9') ~= nil, true)
end

T['turn'] = MiniTest.new_set()

T['turn']['send issues turn/start with text input'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([[_G._test_provider:send('do the thing')]])
  local req = sent_with_method(_G.child, 'turn/start')
  eq(req.params.threadId, 'thread-1')
  eq(req.params.input, { { type = 'text', text = 'do the thing' } })
end

T['turn']['send before thread ready is queued, then flushed'] = function()
  setup_codex(_G.child)
  _G.child.lua([[_G._test_provider:send('early prompt')]])
  eq(sent_with_method(_G.child, 'turn/start'), vim.NIL)
  handshake(_G.child)
  local req = sent_with_method(_G.child, 'turn/start')
  eq(req.params.input[1].text, 'early prompt')
end

T['turn']['streams agent text and completes'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._test_provider:send('hi')
    local req
    for _, m in ipairs(_G._test_sent) do
      if m.method == 'turn/start' then req = m end
    end
    _G._feed({ id = req.id, result = { turn = { id = 'turn-1', items = {}, status = 'inProgress' } } })
    _G._feed({ method = 'turn/started', params = { threadId = 'thread-1',
      turn = { id = 'turn-1', items = {}, status = 'inProgress' } } })
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'agentMessage', id = 'm1', text = '' } } })
    _G._feed({ method = 'item/agentMessage/delta', params = { threadId = 'thread-1',
      turnId = 'turn-1', itemId = 'm1', delta = 'hello ' } })
    _G._feed({ method = 'item/agentMessage/delta', params = { threadId = 'thread-1',
      turnId = 'turn-1', itemId = 'm1', delta = 'world' } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'agentMessage', id = 'm1', text = 'hello world' } } })
    _G._test_turn_active_mid = _G._test_session.turn_active
    _G._feed({ method = 'turn/completed', params = { threadId = 'thread-1',
      turn = { id = 'turn-1', items = {}, status = 'completed', durationMs = 1500 } } })
  ]==])
  eq(_G.child.lua_get('_G._test_turn_active_mid'), true)
  eq(_G.child.lua_get('_G._test_session.turn_active'), false)
  eq(_G.child.lua_get('_G._test_session.is_streaming'), false)
  local text = buffer_text(_G.child)
  eq(text:find('Agent:', 1, true) ~= nil, true)
  eq(text:find('hello world', 1, true) ~= nil, true)
  eq(text:find('1s', 1, true) ~= nil, true) -- durationMs on the cost line
end

T['turn']['item/completed without deltas renders full text'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'agentMessage', id = 'm1', text = '' } } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'agentMessage', id = 'm1', text = 'unstreamed reply' } } })
  ]==])
  eq(buffer_text(_G.child):find('unstreamed reply', 1, true) ~= nil, true)
end

T['turn']['interrupted turn renders timing without usage'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    local function usage(input, cached, output)
      local b = { totalTokens = input + output, inputTokens = input,
        cachedInputTokens = cached, outputTokens = output, reasoningOutputTokens = 0 }
      return { total = b, last = b }
    end
    _G._feed({ method = 'thread/tokenUsage/updated', params = { threadId = 'thread-1',
      turnId = 't0', tokenUsage = usage(1000, 400, 50) } })
    _G._feed({ method = 'turn/started', params = { threadId = 'thread-1',
      turn = { id = 'turn-1', items = {}, status = 'inProgress' } } })
    _G._feed({ method = 'thread/tokenUsage/updated', params = { threadId = 'thread-1',
      turnId = 'turn-1', tokenUsage = usage(1500, 900, 80) } })
    _G._test_sent_before = #_G._test_sent
    _G._test_interrupt_ret = _G._test_provider:interrupt()
    _G._feed({ method = 'turn/completed', params = { threadId = 'thread-1',
      turn = { id = 'turn-1', items = {}, status = 'interrupted', durationMs = 5000 } } })
  ]==])
  eq(_G.child.lua_get('_G._test_interrupt_ret'), true)
  local sent = _G.child.lua_get('_G._test_sent')
  local before = _G.child.lua_get('_G._test_sent_before')
  eq(sent[before + 1].method, 'turn/interrupt')
  eq(sent[before + 1].params.turnId, 'turn-1')
  local text = buffer_text(_G.child)
  local notice = text:find('── Interrupted ──', 1, true)
  local stamp = text:find('── 20%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ │ 5s ──')
  assert(notice, 'expected interrupted notice, got:\n' .. text)
  assert(stamp, 'expected timestamp and duration, got:\n' .. text)
  eq(notice < stamp, true)
  eq(text:find('30 out', 1, true), nil)
  eq(text:find('500 cache read', 1, true), nil)
  eq(_G.child.lua_get('_G._test_session.turn_active'), false)
end

T['turn']['failed turn renders the error message'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'turn/completed', params = { threadId = 'thread-1',
      turn = { id = 'turn-1', items = {}, status = 'failed',
        error = { message = 'usage limit exceeded' } } } })
  ]==])
  eq(buffer_text(_G.child):find('Error: usage limit exceeded', 1, true) ~= nil, true)
end

T['items'] = MiniTest.new_set()

T['items']['commandExecution renders like a Bash tool'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'commandExecution', id = 'c1',
        command = 'echo hi', status = 'inProgress' } } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'commandExecution', id = 'c1',
        command = 'echo hi', status = 'completed', exitCode = 0,
        aggregatedOutput = 'hi\n' } } })
  ]==])
  local text = buffer_text(_G.child)
  eq(text:find('Bash: echo hi', 1, true) ~= nil, true)
  eq(text:find('Output:', 1, true) ~= nil, true)
  eq(text:find('      hi', 1, true) ~= nil, true)
end

T['items']['failed command renders an Error result'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'commandExecution', id = 'c1',
        command = 'false', status = 'inProgress' } } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'commandExecution', id = 'c1',
        command = 'false', status = 'failed', exitCode = 1, aggregatedOutput = '' } } })
  ]==])
  local text = buffer_text(_G.child)
  eq(text:find('Error:', 1, true) ~= nil, true)
  eq(text:find('exit 1', 1, true) ~= nil, true)
end

T['items']['fileChange renders the supplied diff'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'fileChange', id = 'f1', status = 'inProgress',
        changes = { { path = '/tmp/foo.lua', kind = { type = 'update' },
          diff = '@@ -1 +1 @@\n-old line\n+new line' } } } } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'fileChange', id = 'f1', status = 'completed',
        changes = { { path = '/tmp/foo.lua', kind = { type = 'update' },
          diff = '@@ -1 +1 @@\n-old line\n+new line' } } } } })
  ]==])
  local text = buffer_text(_G.child)
  -- Displayed as Edit (TOOL_DISPLAY_NAMES maps FileChange → Edit).
  eq(text:find('Edit: /tmp/foo.lua', 1, true) ~= nil, true)
  eq(text:find('-old line', 1, true) ~= nil, true)
  eq(text:find('+new line', 1, true) ~= nil, true)
end

T['items']['mcpToolCall renders with mcp naming and result text'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'mcpToolCall', id = 't1', server = 'github',
        tool = 'search', arguments = { query = 'bug' }, status = 'inProgress' } } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'mcpToolCall', id = 't1', server = 'github',
        tool = 'search', arguments = { query = 'bug' }, status = 'completed',
        result = { content = { { type = 'text', text = 'found 3 issues' } } } } } })
  ]==])
  local text = buffer_text(_G.child)
  eq(text:find('mcp__github__search', 1, true) ~= nil, true)
  eq(text:find('found 3 issues', 1, true) ~= nil, true)
end

T['items']['reasoning deltas render as thinking when enabled'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'reasoning', id = 'r1' } } })
    _G._feed({ method = 'item/reasoning/summaryTextDelta', params = { threadId = 'thread-1',
      turnId = 'turn-1', itemId = 'r1', summaryIndex = 0, delta = 'pondering deeply' } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'reasoning', id = 'r1' } } })
  ]==])
  local text = buffer_text(_G.child)
  eq(text:find('Thinking', 1, true) ~= nil, true)
  eq(text:find('pondering deeply', 1, true) ~= nil, true)
end

T['items']['plan updates render step markers'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'turn/plan/updated', params = { threadId = 'thread-1', turnId = 'turn-1',
      plan = {
        { step = 'read the code', status = 'completed' },
        { step = 'write the fix', status = 'inProgress' },
        { step = 'run tests', status = 'pending' },
      } } })
  ]==])
  local text = buffer_text(_G.child)
  eq(text:find('▣ Plan:', 1, true) ~= nil, true)
  eq(text:find('✓ read the code', 1, true) ~= nil, true)
  eq(text:find('◐ write the fix', 1, true) ~= nil, true)
  eq(text:find('□ run tests', 1, true) ~= nil, true)
end

T['usage'] = MiniTest.new_set()

T['usage']['token usage maps onto session fields'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'thread/tokenUsage/updated', params = { threadId = 'thread-1',
      turnId = 'turn-1', tokenUsage = {
        total = { totalTokens = 13663, inputTokens = 13658, cachedInputTokens = 9984,
          outputTokens = 5, reasoningOutputTokens = 0 },
        last = { totalTokens = 13663, inputTokens = 13658, cachedInputTokens = 9984,
          outputTokens = 5, reasoningOutputTokens = 0 },
        modelContextWindow = 258400,
      } } })
  ]==])
  -- Codex inputTokens includes cached; session.input_tokens is the fresh share.
  eq(_G.child.lua_get('_G._test_session.input_tokens'), 3674)
  eq(_G.child.lua_get('_G._test_session.output_tokens'), 5)
  eq(_G.child.lua_get('_G._test_session.cache_read_input_tokens'), 9984)
  eq(_G.child.lua_get('_G._test_session.context_tokens'), 13658)
  eq(_G.child.lua_get('_G._test_session.context_window'), 258400)
end

T['usage']['per-turn cost line uses the usage delta'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    local function usage(input, cached, output)
      local b = { totalTokens = input + output, inputTokens = input,
        cachedInputTokens = cached, outputTokens = output, reasoningOutputTokens = 0 }
      return { total = b, last = b }
    end
    _G._feed({ method = 'thread/tokenUsage/updated', params = { threadId = 'thread-1',
      turnId = 't0', tokenUsage = usage(1000, 400, 50) } })
    _G._feed({ method = 'turn/started', params = { threadId = 'thread-1',
      turn = { id = 'turn-2', items = {}, status = 'inProgress' } } })
    _G._feed({ method = 'thread/tokenUsage/updated', params = { threadId = 'thread-1',
      turnId = 'turn-2', tokenUsage = usage(1500, 900, 80) } })
    _G._feed({ method = 'turn/completed', params = { threadId = 'thread-1',
      turn = { id = 'turn-2', items = {}, status = 'completed', durationMs = 2000 } } })
  ]==])
  local text = buffer_text(_G.child)
  -- Deltas across the turn: input +500, all of it cached (+500) → 0 fresh;
  -- output +30; cache read +500.
  eq(text:find('30 out', 1, true) ~= nil, true)
  eq(text:find('500 cache read', 1, true) ~= nil, true)
end

T['approvals'] = MiniTest.new_set()

--- Stub the permission prompt to auto-answer with the given choice.
local function stub_permission_prompt(child, behavior, variant)
  child.lua(string.format([==[
    package.loaded['cc.permission_prompt'] = {
      ask = function(tool_name, input, cb)
        _G._test_asked = { tool_name = tool_name, input = input }
        cb(%q, %q)
      end,
    }
  ]==], behavior, variant))
end

T['approvals']['command approval allow → accept'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  stub_permission_prompt(_G.child, 'allow', 'allow_once')
  _G.child.lua([==[
    _G._feed({ id = 77, method = 'item/commandExecution/requestApproval', params = {
      threadId = 'thread-1', turnId = 'turn-1', itemId = 'c1',
      command = 'rm -rf /tmp/x', cwd = '/tmp', startedAtMs = 0 } })
  ]==])
  local asked = _G.child.lua_get('_G._test_asked')
  eq(asked.tool_name, 'Bash')
  eq(asked.input.command, 'rm -rf /tmp/x')
  local sent = _G.child.lua_get('_G._test_sent')
  local resp = sent[#sent]
  eq(resp.id, 77)
  eq(resp.result.decision, 'accept')
  eq(buffer_text(_G.child):find('✓ Allowed: Bash', 1, true) ~= nil, true)
end

T['approvals']['command approval allow-always → acceptForSession'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  stub_permission_prompt(_G.child, 'allow', 'allow_always')
  _G.child.lua([==[
    _G._feed({ id = 78, method = 'item/commandExecution/requestApproval', params = {
      threadId = 'thread-1', turnId = 'turn-1', itemId = 'c1',
      command = 'make', startedAtMs = 0 } })
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[#sent].result.decision, 'acceptForSession')
end

T['approvals']['command approval deny → decline'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  stub_permission_prompt(_G.child, 'deny', 'deny')
  _G.child.lua([==[
    _G._feed({ id = 79, method = 'item/commandExecution/requestApproval', params = {
      threadId = 'thread-1', turnId = 'turn-1', itemId = 'c1',
      command = 'sudo rm', startedAtMs = 0 } })
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[#sent].result.decision, 'decline')
  eq(buffer_text(_G.child):find('✗ Denied: Bash', 1, true) ~= nil, true)
end

T['approvals']['legacy execCommandApproval uses legacy decisions'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  stub_permission_prompt(_G.child, 'allow', 'allow_once')
  _G.child.lua([==[
    _G._feed({ id = 80, method = 'execCommandApproval', params = {
      conversationId = 'x', callId = 'y', command = { 'ls' }, cwd = '/tmp' } })
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[#sent].result.decision, 'approved')
end

T['approvals']['fileChange approval shows the tracked diff'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  stub_permission_prompt(_G.child, 'allow', 'allow_once')
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'fileChange', id = 'f1', status = 'inProgress',
        changes = { { path = '/tmp/a.txt', kind = { type = 'add' }, diff = '+hi' } } } } })
    _G._feed({ id = 81, method = 'item/fileChange/requestApproval', params = {
      threadId = 'thread-1', turnId = 'turn-1', itemId = 'f1', startedAtMs = 0 } })
  ]==])
  local asked = _G.child.lua_get('_G._test_asked')
  eq(asked.tool_name, 'FileChange')
  eq(asked.input.changes[1].path, '/tmp/a.txt')
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[#sent].id, 81)
  eq(sent[#sent].result.decision, 'accept')
end

T['approvals']['unsupported server requests get an error response'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ id = 90, method = 'item/permissions/requestApproval', params = {} })
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  local resp = sent[#sent]
  eq(resp.id, 90)
  eq(resp.error.code, -32601)
  eq(buffer_text(_G.child):find('unsupported', 1, true) ~= nil, true)
end

T['misc'] = MiniTest.new_set()

T['misc']['error notifications render as notices'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'error', params = { threadId = 'thread-1', turnId = 'turn-1',
      error = { message = 'stream disconnected' }, willRetry = true } })
  ]==])
  eq(buffer_text(_G.child):find('Error: stream disconnected (retrying)', 1, true) ~= nil, true)
end

T['misc']['unknown notifications are safe no-ops'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'model/rerouted', params = { anything = true } })
    _G._feed({ method = 'some/future/notification', params = {} })
    _G._test_ok = true
  ]==])
  eq(_G.child.lua_get('_G._test_ok'), true)
end

T['misc']['unknown item types render nothing but do not error'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'item/started', params = { threadId = 'thread-1', turnId = 'turn-1',
      startedAtMs = 0, item = { type = 'futuristicItem', id = 'z1' } } })
    _G._feed({ method = 'item/completed', params = { threadId = 'thread-1', turnId = 'turn-1',
      completedAtMs = 1, item = { type = 'futuristicItem', id = 'z1' } } })
    _G._test_ok = true
  ]==])
  eq(_G.child.lua_get('_G._test_ok'), true)
end

T['misc']['rename sends thread/name/set'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([[_G._test_rename_sent = _G._test_provider:rename('my-thread')]])
  eq(_G.child.lua_get('_G._test_rename_sent'), true)
  local sent = _G.child.lua_get('_G._test_sent')
  local req = sent[#sent]
  eq(req.method, 'thread/name/set')
  eq(req.params.name, 'my-thread')
  eq(req.params.threadId, 'thread-1')
end

T['misc']['rename before thread ready reports not sent'] = function()
  setup_codex(_G.child)
  eq(_G.child.lua_get([[_G._test_provider:rename('too-early')]]), false)
end

T['misc']['context compaction renders a notice'] = function()
  setup_codex(_G.child)
  handshake(_G.child)
  _G.child.lua([==[
    _G._feed({ method = 'thread/compacted', params = { threadId = 'thread-1' } })
  ]==])
  eq(buffer_text(_G.child):find('Context Compacted', 1, true) ~= nil, true)
end

T['misc']['pending request callbacks fail on close'] = function()
  setup_codex(_G.child)
  _G.child.lua([==[
    local got_err
    _G._test_provider:request('thread/list', {}, function(_, err) got_err = err end)
    _G._test_provider:_fail_pending('gone')
    _G._test_err_msg = got_err and got_err.message
  ]==])
  eq(_G.child.lua_get('_G._test_err_msg'), 'gone')
end

T['fixture'] = MiniTest.new_set()

T['fixture']['replays the captured live session'] = function()
  setup_codex(_G.child)
  _G.child.lua(string.format([==[
    _G._test_provider:_start_protocol()
    -- The captured fixture contains the server side of a real session whose
    -- responses use ids 1 (initialize) and 2 (thread/start) — matching the
    -- ids our provider generates for the same handshake.
    local Parser = require('cc.parser')
    local parser = Parser.new()
    for _, line in ipairs(vim.fn.readfile(%q)) do
      for _, msg in ipairs(parser:feed(line .. '\n')) do
        _G._feed(msg)
      end
    end
  ]==], helpers.repo_root .. '/tests/fixtures/codex/simple_turn.ndjson'))
  eq(_G.child.lua_get('_G._test_session.id'), '019f70e5-59dd-7370-a3c8-9302481671cd')
  eq(_G.child.lua_get('_G._test_session.model'), 'gpt-5.6-sol')
  eq(_G.child.lua_get('_G._test_session.turn_active'), false)
  eq(_G.child.lua_get('_G._test_session.output_tokens'), 5)
  local text = buffer_text(_G.child)
  eq(text:find('hello', 1, true) ~= nil, true)
end

return T
