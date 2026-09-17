local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['limits log'] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      _G.child.lua([[
        _G._test_path = vim.fn.tempname() .. '.jsonl'
        require('cc.config').setup({ limits_log = _G._test_path })
        require('cc.limits_log')._reset()
      ]])
    end,
    post_case = function()
      _G.child.lua([[vim.fn.delete(_G._test_path)]])
    end,
  },
})
local L = T['limits log']

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

--- Read JSONL rows and validate their append-time timestamps.
local function read_rows(child)
  local rows = child.lua_get([[(function()
    local rows = {}
    for _, line in ipairs(vim.fn.readfile(_G._test_path)) do
      table.insert(rows, vim.json.decode(line))
    end
    return rows
  end)()]])
  for _, row in ipairs(rows) do
    eq(row.ts:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%+00:00$') ~= nil, true)
    row.ts = nil
  end
  return rows
end

L['Claude streaming logs each window and deduplicates identical events'] = function()
  local child = _G.child
  helpers.replay_streaming(child, 'rate_limit_unified', { limits_log = child.lua_get('_G._test_path') })
  local rows = read_rows(child)
  -- `status` belongs to the rateLimitType window (five_hour); the unchanged
  -- seven_day reading in the warning event is deduplicated.
  eq(#rows, 3)
  table.sort(rows, function(a, b)
    return a.window .. tostring(a.used_pct) < b.window .. tostring(b.used_pct)
  end)
  eq(rows, {
    { provider = 'claude', window = 'five_hour', used_pct = 31,
      resets_at = 1789681200, status = 'allowed' },
    { provider = 'claude', window = 'five_hour', used_pct = 90,
      resets_at = 1789681200, status = 'allowed_warning' },
    { provider = 'claude', window = 'seven_day', used_pct = 40,
      resets_at = 1789855200 },
  })
end

L['Claude logs utilization changes before render deduplication'] = function()
  local child = _G.child
  helpers.replay_streaming(child, 'rate_limit_unified', { limits_log = child.lua_get('_G._test_path') })
  child.lua([[
    _G._test_router:dispatch({ type = 'rate_limit_event', rate_limit_info = {
      status = 'allowed_warning', rateLimitType = 'five_hour', resetsAt = 1789681200,
      isUsingOverage = false,
      unifiedWindows = { five_hour = { utilization = 0.91, resetsAt = 1789681200 } },
    } })
  ]])
  local rows = read_rows(child)
  eq(#rows, 4)
  eq(rows[4].used_pct, 91)
end

L['Codex notifications log changes after handshake'] = function()
  local child = _G.child
  setup_codex(child, [[{ provider = 'codex', limits_log = _G._test_path }]])
  handshake(child)
  child.lua([[
    for _, line in ipairs(vim.fn.readfile('tests/fixtures/codex/rate_limits.ndjson')) do
      _G._test_provider:_on_message(vim.json.decode(line))
    end
  ]])
  eq(read_rows(child), {
    { provider = 'codex', window = 'five_hour', used_pct = 0,
      resets_at = 1788810242, status = 'allowed', plan = 'team' },
    { provider = 'codex', window = 'seven_day', used_pct = 1,
      resets_at = 1789139360, status = 'allowed', plan = 'team' },
    { provider = 'codex', window = 'five_hour', used_pct = 3,
      resets_at = 1788810242, status = 'allowed', plan = 'team' },
  })
end

L['Codex supports a weekly primary without secondary'] = function()
  eq(_G.child.lua_get([[require('cc.limits_log').from_codex({
    primary = { windowDurationMins = 10080, usedPercent = 12, resetsAt = 123 },
    secondary = nil,
  })]]), {
    { provider = 'codex', window = 'seven_day', used_pct = 12,
      resets_at = 123, status = 'allowed' },
  })
end

L['Codex maps other windows and reached status'] = function()
  eq(_G.child.lua_get([[require('cc.limits_log').from_codex({
    primary = { windowDurationMins = 60, usedPercent = 100 },
    secondary = {}, rateLimitReachedType = 'rate_limit_reached',
  })]]), {
    { provider = 'codex', window = '60m', used_pct = 100, status = 'rate_limit_reached' },
    { provider = 'codex', window = 'unknown', status = 'rate_limit_reached' },
  })
end

L['Claude legacy shape rounds utilization and tolerates missing utilization'] = function()
  eq(_G.child.lua_get([[require('cc.limits_log').from_claude({
    rateLimitType = 'five_hour', utilization = 0.316, resetsAt = 123, status = 'allowed',
  })]]), {
    { provider = 'claude', window = 'five_hour', used_pct = 32,
      resets_at = 123, status = 'allowed' },
  })
  eq(_G.child.lua_get([[require('cc.limits_log').from_claude({
    rateLimitType = 'five_hour', status = 'rejected',
  })]]), {
    { provider = 'claude', window = 'five_hour', status = 'rejected' },
  })
end

L['disabled logging creates no file and does not consume readings'] = function()
  _G.child.lua([[
    local config = require('cc.config')
    local log = require('cc.limits_log')
    local readings = log.from_claude({ rateLimitType = 'five_hour', status = 'allowed' })
    config.setup({})
    log.append(readings)
    config.setup({ limits_log = false })
    log.append(readings)
    config.setup({ limits_log = '' })
    log.append(readings)
    _G._test_exists = vim.fn.filereadable(_G._test_path)
    config.setup({ limits_log = _G._test_path })
    log.append(readings)
  ]])
  eq(_G.child.lua_get('_G._test_exists'), 0)
  eq(#read_rows(_G.child), 1)
end

L['record helpers ignore non-table input'] = function()
  _G.child.lua([[
    local log = require('cc.limits_log')
    for _, value in ipairs({ false, 'bad', 123, vim.NIL }) do
      log.record_claude(value)
      log.record_codex(value)
    end
    log.record_claude(nil)
    log.record_codex(nil)
  ]])
  eq(_G.child.lua_get('vim.fn.filereadable(_G._test_path)'), 0)
end

L['append expands paths and creates parent directories'] = function()
  _G.child.lua([[
    local root = vim.fn.tempname()
    vim.env.CC_TEST_LIMITS_DIR = root
    require('cc.config').setup({ limits_log = '$CC_TEST_LIMITS_DIR/nested/readings.jsonl' })
    require('cc.limits_log').record_codex({ primary = {} })
    _G._test_lines = vim.fn.readfile(root .. '/nested/readings.jsonl')
    vim.fn.delete(root, 'rf')
    vim.env.CC_TEST_LIMITS_DIR = nil
  ]])
  eq(#_G.child.lua_get('_G._test_lines'), 1)
end

L['open failure warns once and can retry the same reading'] = function()
  _G.child.lua([[
    local config = require('cc.config')
    local log = require('cc.limits_log')
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level) table.insert(notices, { msg = msg, level = level }) end
    -- A regular file cannot be the parent directory of the log.
    vim.fn.writefile({}, _G._test_path)
    config.setup({ limits_log = _G._test_path .. '/readings.jsonl' })
    log.record_codex({ primary = {} })
    log.record_codex({ primary = {} })
    vim.notify = original_notify
    _G._test_notices = notices
    config.setup({ limits_log = _G._test_path })
    log.record_codex({ primary = {} })
  ]])
  local notices = _G.child.lua_get('_G._test_notices')
  eq(#notices, 1)
  eq(notices[1].level, vim.log.levels.WARN)
  eq(notices[1].msg:find('limits_log', 1, true) ~= nil, true)
  eq(#read_rows(_G.child), 1)
end

L['dedupe tracks resets and status independently per provider and window'] = function()
  _G.child.lua([[
    local log = require('cc.limits_log')
    local info = { rateLimitType = 'five_hour', utilization = 0.1, resetsAt = 1, status = 'allowed' }
    log.record_claude(info)
    log.record_claude(info)
    info.resetsAt = 2
    log.record_claude(info)
    info.status = 'rejected'
    log.record_claude(info)
    log.record_codex({ primary = { windowDurationMins = 300, usedPercent = 10, resetsAt = 2 },
      rateLimitReachedType = 'rejected' })
    log._reset()
    log.record_claude(info)
  ]])
  eq(#read_rows(_G.child), 5)
end

return T
