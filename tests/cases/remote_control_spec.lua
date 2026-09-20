-- Remote Control over Claude's existing stream-json control channel.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

local URL = 'https://claude.ai/code/session_01TLKUiPoDxXmcyfLagdvLev'
local BRIDGE_ID = 'cse_01TLKUiPoDxXmcyfLagdvLev'

local function setup_pipeline()
  _G.child.lua([[
    require('cc.config').setup({})
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-output')
    _G._test_bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(_G._test_bufnr)
    local process = require('cc.process').new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    _G._test_sent = {}
    process.write = function(_, msg) table.insert(_G._test_sent, msg) end
    local router = require('cc.router').new({ session = session, output = output, process = process })
    local parser = require('cc.parser').new()
    _G._test_feed = function(line)
      for _, msg in ipairs(parser:feed(line .. '\n')) do router:dispatch(msg) end
    end
    _G._test_session = session
    _G._test_output = output
    _G._test_process = process
    _G._test_router = router
  ]])
end

local function assert_output(text)
  local lines = table.concat(helpers.get_buffer_lines(_G.child), '\n')
  eq(lines:find(text, 1, true) ~= nil, true)
end

T['history.last_bridge_session reads the last binding and tolerates missing files'] = function()
  _G.child.lua([[
    local history = require('cc.history')
    local path = vim.fn.tempname()
    local lines = {
      '{"type":"user","message":{"content":"hello"}}',
      '{"type":"bridge-session","bridgeSessionId":"cse_A"}',
      '{"type":"bridge-session","bridgeSessionId":""}',
      '{"type": "bridge-session","bridgeSessionId":"cse_B"}',
    }
    vim.fn.writefile(lines, path)
    local decode = vim.json.decode
    local decoded = 0
    vim.json.decode = function(...)
      decoded = decoded + 1
      return decode(...)
    end
    _G._test_last = history.last_bridge_session(path)
    vim.json.decode = decode
    _G._test_decoded = decoded
    table.remove(lines)
    vim.fn.writefile(lines, path)
    _G._test_cleared = history.last_bridge_session(path)
    vim.fn.writefile({ lines[1] }, path)
    _G._test_none = history.last_bridge_session(path) == nil
    vim.fn.delete(path)
    _G._test_missing = history.last_bridge_session(path) == nil
  ]])
  eq(_G.child.lua_get('_G._test_last'), 'cse_B')
  eq(_G.child.lua_get('_G._test_decoded'), 3)
  eq(_G.child.lua_get('_G._test_cleared'), '')
  eq(_G.child.lua_get('_G._test_none'), true)
  eq(_G.child.lua_get('_G._test_missing'), true)
end

local function setup_resumed_provider(binding, resumed)
  setup_pipeline()
  _G.child.lua(([==[
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, 'p')
    local provider = require('cc.providers.claude').attach({
      session = _G._test_session, output = _G._test_output,
      resume_id = %s, cwd = cwd,
    })
    _G._test_process.opts.cwd = provider.process.opts.cwd
    provider.process = _G._test_process
    _G._test_provider = provider
    _G._test_binding = %s
    _G._test_reads = 0
    _G._test_paths = {}
    _G._test_callbacks = {}
    _G._test_enable = function()
      local history = require('cc.history')
      local session_path, last_bridge_session = history.session_path, history.last_bridge_session
      history.session_path = function(id, dir)
        assert(dir == cwd)
        table.insert(_G._test_paths, id)
        if _G._test_missing_current and id ~= 'resumed-id' then return nil end
        return cwd .. '/' .. id .. '.jsonl'
      end
      history.last_bridge_session = function(path)
        _G._test_reads = _G._test_reads + 1
        _G._test_read_path = path
        if _G._test_read_error then error('read failed') end
        return _G._test_binding
      end
      local ok, id = pcall(function()
        return provider:set_remote_control(true, 'phone', function(success, err)
          table.insert(_G._test_callbacks, { ok = success, error = err })
        end)
      end)
      history.session_path, history.last_bridge_session = session_path, last_bridge_session
      if not ok then error(id) end
      return id
    end
    _G._test_respond = function(index, response, err)
      _G._test_feed(vim.json.encode({ type = 'control_response', response = {
        subtype = err and 'error' or 'success', request_id = _G._test_sent[index].request_id,
        response = response or {}, error = err,
      } }))
    end
    vim.fn.delete(cwd, 'd')
  ]==]):format(resumed == false and 'nil' or "'resumed-id'", vim.inspect(binding)))
end

T['resumed stale bridge cycles silently and subsequent enable sends one request'] = function()
  setup_resumed_provider('cse_old')
  _G.child.lua([[
    _G._test_first_id = _G._test_enable()
    assert(_G._test_first_id == _G._test_sent[1].request_id)
    assert(_G._test_process._pending_controls[_G._test_first_id].silent == true)
    _G._test_respond(1, { session_url = 'old', bridge_session_id = 'cse_old' })
  ]])
  eq(_G.child.lua_get('_G._test_session.remote_control_url'), 'old')
  eq(_G.child.lua_get('#_G._test_callbacks'), 0)
  _G.child.lua('_G._test_respond(2)')
  eq(_G.child.lua_get('_G._test_session.remote_control_url == nil'), true)
  eq(_G.child.lua_get('_G._test_provider._bridge_binding_cleared'), true)
  eq(_G.child.lua_get('#_G._test_callbacks'), 0)
  _G.child.lua(([==[
    _G._test_respond(3, { session_url = %q, bridge_session_id = %q })
  ]==]):format(URL, BRIDGE_ID))
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 3)
  eq(sent[1].request, { subtype = 'remote_control', enabled = true })
  eq(sent[2].request, { subtype = 'remote_control', enabled = false })
  eq(sent[3].request, { subtype = 'remote_control', enabled = true, name = 'phone' })
  assert_output('Remote Control: re-creating the claude.ai session so history syncs')
  assert_output('Remote Control: ' .. URL)
  local lines = table.concat(helpers.get_buffer_lines(_G.child), '\n')
  eq(lines:find('Remote Control: old', 1, true), nil)
  eq(lines:find('Remote Control disabled', 1, true), nil)
  eq(_G.child.lua_get('_G._test_session.remote_control_url'), URL)
  eq(_G.child.lua_get('_G._test_session.remote_control_bridge_id'), BRIDGE_ID)
  eq(_G.child.lua_get('_G._test_callbacks'), { { ok = true } })
  _G.child.lua('_G._test_enable()')
  eq(_G.child.lua_get('#_G._test_sent'), 4)
  eq(_G.child.lua_get('_G._test_sent[4].request'), {
    subtype = 'remote_control', enabled = true, name = 'phone',
  })
  eq(_G.child.lua_get('_G._test_reads'), 1)
end

T['resumed cleared binding enables once and skips later transcript reads'] = function()
  setup_resumed_provider('')
  _G.child.lua([[
    _G._test_enable()
    _G._test_respond(1, { session_url = 'fresh' })
    _G._test_enable()
  ]])
  eq(_G.child.lua_get('#_G._test_sent'), 2)
  eq(_G.child.lua_get('_G._test_reads'), 1)
  eq(_G.child.lua_get('_G._test_provider._bridge_binding_cleared'), true)
  eq(_G.child.lua_get('_G._test_callbacks'), { { ok = true } })
  assert_output('Remote Control: fresh')
end

T['new provider never reads the transcript'] = function()
  setup_resumed_provider('cse_old', false)
  _G.child.lua('_G._test_read_error = true; _G._test_enable()')
  eq(_G.child.lua_get('_G._test_reads'), 0)
  eq(_G.child.lua_get('_G._test_paths'), {})
  eq(_G.child.lua_get('#_G._test_sent'), 1)
end

T['transcript read failure falls through to a normal enable'] = function()
  setup_resumed_provider('cse_old')
  _G.child.lua('_G._test_read_error = true; _G._test_enable()')
  eq(_G.child.lua_get('#_G._test_sent'), 1)
  eq(_G.child.lua_get('_G._test_sent[1].request.name'), 'phone')
  eq(_G.child.lua_get('_G._test_process._pending_controls[_G._test_sent[1].request_id].silent == nil'), true)
end

for _, missing in ipairs({ false, true }) do
  T['resumed bridge resolves current session path with fallback: ' .. tostring(missing)] = function()
    setup_resumed_provider('cse_old')
    _G.child.lua(([==[
      _G._test_provider.instance = { last_session_id = 'current-id' }
      _G._test_missing_current = %s
      _G._test_enable()
    ]==]):format(tostring(missing)))
    eq(_G.child.lua_get('_G._test_paths'), missing and { 'current-id', 'resumed-id' } or { 'current-id' })
    eq(_G.child.lua_get('_G._test_read_path == _G._test_process.opts.cwd .. "/" .. _G._test_paths[#_G._test_paths] .. ".jsonl"'), true)
    eq(_G.child.lua_get('_G._test_sent[1].request.name == nil'), true)
  end
end

for _, step in ipairs({ 1, 2 }) do
  T['resync failure at step ' .. step .. ' reports once and stops the cycle'] = function()
    setup_resumed_provider('cse_old')
    _G.child.lua(([==[
      require('cc.config').setup({ remote_control = { resync_notice = 'Syncing history', error_format = 'Problem: %%s' } })
      _G._test_enable()
      if %d == 2 then _G._test_respond(1, { session_url = 'old' }) end
      local notify = vim.notify
      _G._test_notices = {}
      vim.notify = function(msg, level) table.insert(_G._test_notices, { msg = msg, level = level }) end
      _G._test_respond(%d, nil, 'bridge unavailable')
      vim.notify = notify
    ]==]):format(step, step))
    eq(_G.child.lua_get('#_G._test_sent'), step)
    eq(_G.child.lua_get('_G._test_callbacks'), { { ok = false, error = 'bridge unavailable' } })
    eq(_G.child.lua_get('_G._test_provider._bridge_binding_cleared == nil'), true)
    eq(_G.child.lua_get('_G._test_notices'), { {
      msg = 'cc.nvim: Problem: bridge unavailable', level = vim.log.levels.WARN,
    } })
    assert_output('Syncing history')
    assert_output('Problem: bridge unavailable')
    local lines = table.concat(helpers.get_buffer_lines(_G.child), '\n')
    local _, count = lines:gsub('Problem: bridge unavailable', '')
    eq(count, 1)
  end
end

T['streaming fixture correlates the enable response and updates bridge state'] = function()
  setup_pipeline()
  _G.child.lua(([==[
    local id = _G._test_process:set_remote_control(true, nil, function(ok)
      _G._test_callback_ok = ok
    end)
    _G._test_fixture = vim.fn.readfile(%q)
    _G._test_fixture[2] = _G._test_fixture[2]:gsub('REMOTE_REQUEST_ID', id)
    _G._test_feed(_G._test_fixture[1])
  ]==]):format(helpers.ndjson_fixtures_dir .. '/remote_control.ndjson'))
  eq(_G.child.lua_get('_G._test_session.remote_control_state'), 'ready')
  eq(_G.child.lua_get('_G._test_session.remote_control_url == nil'), true)
  _G.child.lua('_G._test_feed(_G._test_fixture[2])')
  eq(_G.child.lua_get('_G._test_session.remote_control_url'), URL)
  eq(_G.child.lua_get('_G._test_session.remote_control_bridge_id'), BRIDGE_ID)
  eq(_G.child.lua_get('_G._test_callback_ok'), true)
  eq(_G.child.lua_get('next(_G._test_process._pending_controls) == nil'), true)
  assert_output('Remote Control: ' .. URL)
  _G.child.lua('_G._test_feed(_G._test_fixture[3])')
  eq(_G.child.lua_get('_G._test_session.remote_control_state'), 'connected')
end

T['bridge failure stores detail and renders it; later state clears detail'] = function()
  setup_pipeline()
  _G.child.lua([[
    _G._test_feed('{"type":"system","subtype":"bridge_state","state":"failed","detail":"connection lost"}')
  ]])
  eq(_G.child.lua_get('_G._test_session.remote_control_state'), 'failed')
  eq(_G.child.lua_get('_G._test_session.remote_control_detail'), 'connection lost')
  assert_output('Remote Control failed: connection lost')
  _G.child.lua([[
    _G._test_feed('{"type":"system","subtype":"bridge_state","state":"reconnecting"}')
  ]])
  eq(_G.child.lua_get('_G._test_session.remote_control_state'), 'reconnecting')
  eq(_G.child.lua_get('_G._test_session.remote_control_detail == nil'), true)
end

T['bridge failure without detail uses the configured fallback'] = function()
  setup_pipeline()
  _G.child.lua([[
    _G._test_feed('{"type":"system","subtype":"bridge_state","state":"failed"}')
  ]])
  assert_output('Remote Control failed: bridge failed')
end

T['enable error renders and warns with CLI text and invokes callback'] = function()
  setup_pipeline()
  _G.child.lua([[
    local id = _G._test_process:set_remote_control(true, nil, function(ok, resp)
      _G._test_callback = { ok = ok, error = resp.error }
    end)
    local notify = vim.notify
    _G._test_notices = {}
    vim.notify = function(msg, level)
      table.insert(_G._test_notices, { msg = msg, level = level })
    end
    _G._test_feed(vim.json.encode({ type = 'control_response', response = {
      subtype = 'error', request_id = id, error = 'Remote Control initialization failed',
    } }))
    vim.notify = notify
  ]])
  assert_output('Remote Control failed: Remote Control initialization failed')
  eq(_G.child.lua_get('_G._test_callback'), {
    ok = false, error = 'Remote Control initialization failed',
  })
  eq(_G.child.lua_get('_G._test_notices'), { {
    msg = 'cc.nvim: Remote Control failed: Remote Control initialization failed',
    level = vim.log.levels.WARN,
  } })
end

T['disable acknowledgement clears every bridge field and invokes callback'] = function()
  setup_pipeline()
  _G.child.lua([[
    local s = _G._test_session
    s.remote_control_state = 'connected'
    s.remote_control_detail = 'old detail'
    s.remote_control_url = 'https://claude.ai/code/session_old'
    s.remote_control_bridge_id = 'cse_old'
    local id = _G._test_process:set_remote_control(false, nil, function(ok)
      _G._test_callback_ok = ok
    end)
    _G._test_feed(vim.json.encode({ type = 'control_response', response = {
      subtype = 'success', request_id = id, response = {},
    } }))
  ]])
  for _, field in ipairs({ 'state', 'detail', 'url', 'bridge_id' }) do
    eq(_G.child.lua_get('_G._test_session.remote_control_' .. field .. ' == nil'), true)
  end
  eq(_G.child.lua_get('_G._test_callback_ok'), true)
  eq(_G.child.lua_get('_G._test_sent[1].request'), { subtype = 'remote_control', enabled = false })
  assert_output('Remote Control disabled')
end

T['notices honor config overrides'] = function()
  setup_pipeline()
  _G.child.lua([[
    require('cc.config').setup({ remote_control = {
      notice_format = 'Link: %s', disabled_notice = 'Off', error_format = 'Problem: %s',
    } })
    local id = _G._test_process:set_remote_control(true)
    _G._test_feed(vim.json.encode({ type = 'control_response', response = {
      subtype = 'success', request_id = id, response = { session_url = 'test-url' },
    } }))
    id = _G._test_process:set_remote_control(false)
    _G._test_feed(vim.json.encode({ type = 'control_response', response = {
      subtype = 'success', request_id = id, response = {},
    } }))
    _G._test_feed('{"type":"system","subtype":"bridge_state","state":"failed","detail":"offline"}')
  ]])
  assert_output('Link: test-url')
  assert_output('Off')
  assert_output('Problem: offline')
end

T['argument parser'] = MiniTest.new_set()
for _, case in ipairs({
  { {}, {} },
  { { 'remote' }, { remote = true } },
  { { 'opus', 'remote' }, { model = 'opus', remote = true } },
  { { 'remote', 'opus', 'high' }, { model = 'opus', effort = 'high', remote = true } },
  { { 'opus', 'high', 'remote=phone' }, { model = 'opus', effort = 'high', remote = 'phone' } },
  { { 'remote=my title' }, { remote = 'my title' } },
  { { 'remote=' }, { remote = true } },
}) do
  T['argument parser'][vim.inspect(case[1])] = function()
    _G.child.lua(('require("cc.config").setup({}); _G._test_args = %s'):format(vim.inspect(case[1])))
    eq(_G.child.lua_get("require('cc.commands').parse_new_args(_G._test_args)"), case[2])
    eq(_G.child.lua_get('_G._test_args'), case[1])
  end
end

T['argument parser']['rejects excess positional args and invalid effort'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    local parse = require('cc.commands').parse_new_args
    _G._test_errors = {}
    for _, args in ipairs({ { 'opus', 'high', 'extra' }, { 'opus', 'high', 'extra', 'remote' } }) do
      local opts, err = parse(args)
      assert(opts == nil)
      table.insert(_G._test_errors, err)
    end
    local opts, err = parse({ 'remote', 'opus', 'invalid' })
    _G._test_invalid = opts == nil and err:find('invalid effort', 1, true) ~= nil
  ]])
  eq(_G.child.lua_get('_G._test_errors'), {
    'cc.nvim: :CcNew [model] [effort] [remote[=name]]',
    'cc.nvim: :CcNew [model] [effort] [remote[=name]]',
  })
  eq(_G.child.lua_get('_G._test_invalid'), true)
end

T['completion offers remote in all slots and keeps positional completion'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    local create = vim.api.nvim_create_user_command
    local complete
    vim.api.nvim_create_user_command = function(name, _, opts)
      if name == 'CcNew' then complete = opts.complete end
    end
    require('cc.commands').create()
    vim.api.nvim_create_user_command = create
    _G._test_completions = {}
    for _, line in ipairs({
      'CcNew ', 'CcNew opus ', 'CcNew opus high ',
      'CcNew remote ', 'CcNew opus remote ', 'CcNew remote opus high ',
      'CcNew opus high rem',
    }) do
      local lead = line:match('(%S+)$') or ''
      _G._test_completions[line] = complete(lead, line, #line)
    end
  ]])
  local completions = _G.child.lua_get('_G._test_completions')
  for _, line in ipairs({ 'CcNew ', 'CcNew opus ', 'CcNew opus high ' }) do
    eq(vim.tbl_contains(completions[line], 'remote'), true)
  end
  eq(completions['CcNew opus high '], { 'remote' })
  eq(completions['CcNew opus high rem'], { 'remote' })
  eq(vim.tbl_contains(completions['CcNew '], 'sonnet'), true)
  eq(vim.tbl_contains(completions['CcNew opus '], 'high'), true)
  eq(vim.tbl_contains(completions['CcNew remote '], 'sonnet'), true)
  eq(vim.tbl_contains(completions['CcNew remote '], 'remote'), false)
  eq(vim.tbl_contains(completions['CcNew opus remote '], 'high'), true)
  eq(vim.tbl_contains(completions['CcNew opus remote '], 'remote'), false)
  eq(completions['CcNew remote opus high '], {})
end

T['permission and interactive responses clear awaiting_permission'] = function()
  setup_pipeline()
  _G.child.lua([[
    local inst = { session = _G._test_session, process = _G._test_process }
    _G._test_router.instance = inst
    local prompt = require('cc.permission_prompt')
    local ask = prompt.ask
    local answer
    prompt.ask = function(_, _, cb) answer = cb end
    _G._test_router:dispatch({ type = 'control_request', request_id = 'permission', request = {
      subtype = 'can_use_tool', tool_name = 'Bash', input = { command = 'pwd' },
    } })
    _G._test_waiting = inst.awaiting_permission
    answer('allow', 'allow_once')
    prompt.ask = ask
    _G._test_cleared = not inst.awaiting_permission and not inst.awaiting_input
    _G._test_router:dispatch({ type = 'control_request', request_id = 'plan', request = {
      subtype = 'can_use_tool', tool_name = 'EnterPlanMode', input = {},
    } })
    _G._test_interactive_cleared = not inst.awaiting_permission and not inst.awaiting_input
  ]])
  eq(_G.child.lua_get('_G._test_waiting'), true)
  eq(_G.child.lua_get('_G._test_cleared'), true)
  eq(_G.child.lua_get('_G._test_interactive_cleared'), true)
end

local function open_permission(request_id, answer_locally)
  setup_pipeline()
  _G.child.lua(([==[
    local router = _G._test_router
    router.instance = {
      session = _G._test_session, process = _G._test_process,
      awaiting_permission = true, awaiting_input = true,
    }
    _G._test_dismissed = 0
    local prompt = require('cc.permission_prompt')
    local ask = prompt.ask
    prompt.ask = function(_, _, on_choice)
      if %s then on_choice('allow', 'allow_once') end
      return { dismiss = function() _G._test_dismissed = _G._test_dismissed + 1 end }
    end
    router:dispatch({ type = 'control_request', request_id = %q, request = {
      subtype = 'can_use_tool', tool_name = 'Bash', input = { command = 'pwd' },
    } })
    prompt.ask = ask
  ]==]):format(tostring(answer_locally or false), request_id))
end

T['remote cancellation dismisses the permission prompt without answering'] = function()
  open_permission('req-1')
  eq(_G.child.lua_get('_G._test_router.open_prompts["req-1"].tool_name'), 'Bash')
  _G.child.lua([[
    _G._test_feed('{"type":"control_cancel_request","request_id":"req-1"}')
  ]])
  eq(_G.child.lua_get('_G._test_dismissed'), 1)
  eq(_G.child.lua_get('_G._test_sent'), {})
  eq(_G.child.lua_get('_G._test_router.instance.awaiting_permission'), false)
  eq(_G.child.lua_get('_G._test_router.instance.awaiting_input'), false)
  eq(_G.child.lua_get('_G._test_router.open_prompts["req-1"] == nil'), true)
  assert_output('⇄ Answered remotely: Bash')
  local lines = helpers.get_buffer_lines(_G.child)
  _G.child.lua([[
    _G._test_feed('{"type":"control_cancel_request","request_id":"req-1"}')
  ]])
  eq(_G.child.lua_get('_G._test_dismissed'), 1)
  eq(_G.child.lua_get('_G._test_sent'), {})
  eq(helpers.get_buffer_lines(_G.child), lines)
end

T['remote cancellation for an unknown request is a no-op'] = function()
  setup_pipeline()
  local lines = helpers.get_buffer_lines(_G.child)
  _G.child.lua([[
    _G._test_feed('{"type":"control_cancel_request","request_id":"unknown"}')
  ]])
  eq(_G.child.lua_get('_G._test_sent'), {})
  eq(helpers.get_buffer_lines(_G.child), lines)
end

T['local permission answer wins before remote cancellation'] = function()
  open_permission('req-1', true)
  eq(_G.child.lua_get('_G._test_router.open_prompts["req-1"] == nil'), true)
  _G.child.lua([[
    _G._test_feed('{"type":"control_cancel_request","request_id":"req-1"}')
  ]])
  eq(_G.child.lua_get('#_G._test_sent'), 1)
  eq(_G.child.lua_get('_G._test_sent[1].type'), 'control_response')
  eq(_G.child.lua_get('_G._test_sent[1].response.response.behavior'), 'allow')
  eq(_G.child.lua_get('_G._test_dismissed'), 0)
  assert_output('✓ Allowed: Bash')
end

for _, outcome in ipairs({
  { behavior = 'allow', text = '✓ Allowed: Bash' },
  { behavior = 'deny', text = '✗ Denied: Bash' },
  { behavior = 'unknown', text = '⇄ Answered remotely: Bash' },
  { text = '⇄ Answered remotely: Bash' },
}) do
  T['echoed permission response dismisses with outcome ' .. (outcome.behavior or 'missing')] = function()
    open_permission('req-2')
    _G.child.lua(([==[
      _G._test_feed(vim.json.encode({ type = 'control_response', response = {
        subtype = 'success', request_id = 'req-2', response = %s,
      } }))
    ]==]):format(outcome.behavior and ('{ behavior = %q }'):format(outcome.behavior) or 'nil'))
    eq(_G.child.lua_get('_G._test_dismissed'), 1)
    eq(_G.child.lua_get('_G._test_sent'), {})
    eq(_G.child.lua_get('_G._test_router.instance.awaiting_permission'), false)
    eq(_G.child.lua_get('_G._test_router.instance.awaiting_input'), false)
    eq(_G.child.lua_get('_G._test_router.open_prompts["req-2"] == nil'), true)
    assert_output(outcome.text)
  end
end

local function setup_open()
  _G.child.lua([[
    require('cc.config').setup({ splash = false, statusline = { enabled = false } })
    _G._test_open = function(opts)
      local P = require('cc.providers.claude')
      local attach = P.attach
      local remote
      P.attach = function(ctx)
        remote = ctx.remote
        return { spawn = function() end, is_alive = function() return false end, close = function() end }
      end
      require('cc').open(opts)
      P.attach = attach
      return remote
    end
  ]])
end

T['open threads explicit remote through the provider context'] = function()
  setup_open()
  eq(_G.child.lua_get('_G._test_open({ remote = true })'), true)
  eq(_G.child.lua_get('_G._test_open({ remote = "phone" })'), 'phone')
end

T['CcNew uses the parser and passes the remote title'] = function()
  setup_open()
  _G.child.lua([[
    local cc = require('cc')
    local open = cc.open
    cc.open = function(opts) _G._test_opts = opts end
    require('cc.commands').create()
    vim.cmd('CcNew remote=phone opus high')
    cc.open = open
  ]])
  eq(_G.child.lua_get('_G._test_opts'), { model = 'opus', effort = 'high', remote = 'phone' })
end

T['no-session toggle is consumed once by the next open'] = function()
  setup_open()
  _G.child.lua([[ require('cc.commands').create(); vim.cmd('CcRemote phone') ]])
  eq(_G.child.lua_get('_G._test_open()'), 'phone')
  eq(_G.child.lua_get('_G._test_open() == nil'), true)
end

T['no-session toggle can be cancelled and unnamed toggle stashes true'] = function()
  setup_open()
  _G.child.lua([[ vim.cmd('CcRemote'); vim.cmd('CcRemote') ]])
  eq(_G.child.lua_get('_G._test_open() == nil'), true)
  _G.child.lua([[ vim.cmd('CcRemote') ]])
  eq(_G.child.lua_get('_G._test_open()'), true)
  eq(_G.child.lua_get('_G._test_open() == nil'), true)
end

T['explicit remote option leaves pending setting for the next implicit open'] = function()
  setup_open()
  _G.child.lua([[ require('cc').remote_control('pending') ]])
  eq(_G.child.lua_get('_G._test_open({ remote = false })'), false)
  eq(_G.child.lua_get('_G._test_open()'), 'pending')
  eq(_G.child.lua_get('_G._test_open() == nil'), true)
end

T['live Claude toggle sends enable, optional name, and disable for active states'] = function()
  setup_pipeline()
  _G.child.lua([[
    local P = require('cc.providers.claude')
    local provider = P.attach({ session = _G._test_session, output = _G._test_output })
    provider.process = _G._test_process
    require('cc')._register_test_instance(_G._test_bufnr, {
      provider = provider, process = provider.process, session = _G._test_session,
    })
    require('cc.commands').create()
    local notify = vim.notify
    _G._test_notices = {}
    vim.notify = function(msg, level) table.insert(_G._test_notices, { msg = msg, level = level }) end
    vim.cmd('CcRemote')
    vim.cmd('CcRemote phone')
    for _, state in ipairs({ 'connected', 'ready', 'reconnecting' }) do
      _G._test_session.remote_control_state = state
      vim.cmd('CcRemote')
    end
    _G._test_session.remote_control_state = 'failed'
    vim.cmd('CcRemote')
    vim.notify = notify
  ]])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 6)
  for _, msg in ipairs(sent) do
    eq(msg.type, 'control_request')
    eq(type(msg.request_id), 'string')
  end
  eq(sent[1].request, { subtype = 'remote_control', enabled = true })
  eq(sent[2].request, { subtype = 'remote_control', enabled = true, name = 'phone' })
  for i = 3, 5 do eq(sent[i].request, { subtype = 'remote_control', enabled = false }) end
  eq(sent[6].request.enabled, true)
  local notices = _G.child.lua_get('_G._test_notices')
  eq(notices[1], { msg = 'cc.nvim: remote control → enabling (requested)', level = vim.log.levels.INFO })
  eq(notices[3], { msg = 'cc.nvim: remote control → disabling (requested)', level = vim.log.levels.INFO })
end

T['Codex live and configured providers warn without sending or stashing'] = function()
  setup_pipeline()
  _G.child.lua([[
    require('cc')._register_test_instance(_G._test_bufnr, {
      process = _G._test_process, session = _G._test_session,
      provider = { name = 'codex', capabilities = require('cc.providers.codex').capabilities },
    })
    local notify = vim.notify
    _G._test_notices = {}
    vim.notify = function(msg, level) table.insert(_G._test_notices, { msg = msg, level = level }) end
    vim.cmd('CcRemote')
    _G._test_process.alive = false
    require('cc.config').setup({ provider = 'codex' })
    vim.cmd('CcRemote phone')
    vim.notify = notify
  ]])
  eq(_G.child.lua_get('#_G._test_sent'), 0)
  local notices = _G.child.lua_get('_G._test_notices')
  eq(#notices, 2)
  for _, notice in ipairs(notices) do
    eq(notice.level, vim.log.levels.WARN)
    eq(notice.msg:find('remote control is Claude-specific', 1, true) ~= nil, true)
  end
  setup_open()
  eq(_G.child.lua_get('_G._test_open() == nil'), true)
end

T['Claude spawn seeds Remote Control and omits empty names'] = function()
  setup_pipeline()
  _G.child.lua([[
    local P = require('cc.providers.claude')
    _G._test_requests = {}
    for _, remote in ipairs({ true, 'phone', '' }) do
      local provider = P.attach({ session = _G._test_session, output = _G._test_output, remote = remote })
      provider.process = _G._test_process
      provider.process.spawn = function() end
      provider.opts.effort = 'auto'
      provider:spawn()
    end
    for _, msg in ipairs(_G._test_sent) do
      if msg.request.subtype == 'remote_control' then table.insert(_G._test_requests, msg.request) end
    end
  ]])
  eq(_G.child.lua_get('_G._test_requests'), {
    { subtype = 'remote_control', enabled = true },
    { subtype = 'remote_control', enabled = true, name = 'phone' },
    { subtype = 'remote_control', enabled = true },
  })
end

T['Claude wrapper returns errors to callbacks including a dead process'] = function()
  setup_pipeline()
  _G.child.lua([[
    local P = require('cc.providers.claude')
    local provider = P.attach({ session = _G._test_session, output = _G._test_output })
    provider.process = _G._test_process
    local id = provider:set_remote_control(true, nil, function(ok, err)
      _G._test_callback = { ok = ok, error = err }
    end)
    local notify = vim.notify
    vim.notify = function() end
    _G._test_feed(vim.json.encode({ type = 'control_response', response = {
      subtype = 'error', request_id = id, error = 'Remote Control initialization failed',
    } }))
    vim.notify = notify
    provider.process.alive = false
    _G._test_dead_id = provider:set_remote_control(true, nil, function(ok, err)
      _G._test_dead = { ok = ok, error = err }
    end)
  ]])
  eq(_G.child.lua_get('_G._test_callback'), { ok = false, error = 'Remote Control initialization failed' })
  eq(_G.child.lua_get('_G._test_dead'), { ok = false, error = 'process not alive' })
  eq(_G.child.lua_get('_G._test_dead_id == nil'), true)
  eq(_G.child.lua_get('#_G._test_sent'), 1)
end

T['remote prompt fixture renders a user turn and ignores command lifecycle'] = function()
  setup_pipeline()
  _G.child.lua(([==[
    _G._test_fixture = vim.fn.readfile(%q)
    _G._test_feed(_G._test_fixture[1])
  ]==]):format(helpers.ndjson_fixtures_dir .. '/remote_prompt.ndjson'))
  assert_output('What does this repo do?')
  eq(_G.child.lua_get('_G._test_session.turns'), { { role = 'user', text = 'What does this repo do?' } })
  eq(_G.child.lua_get('_G._test_session.turn_active'), true)
  local lines = helpers.get_buffer_lines(_G.child)
  _G.child.lua('_G._test_feed(_G._test_fixture[2])')
  eq(helpers.get_buffer_lines(_G.child), lines)
  eq(_G.child.lua_get('#_G._test_session.turns'), 1)
end

T['own prompt echo consumes the sent UUID without rendering'] = function()
  setup_pipeline()
  local lines = helpers.get_buffer_lines(_G.child)
  _G.child.lua([[
    local provider = require('cc.providers.claude').attach({ session = _G._test_session, output = _G._test_output })
    provider.process = _G._test_process
    provider:send('hello from nvim')
    local sent = _G._test_sent[1]
    assert(type(sent.uuid) == 'string')
    assert(_G._test_session.sent_prompt_uuids[sent.uuid] == true)
    _G._test_output.render_user_turn = function() error('own echo rendered') end
    _G._test_feed(vim.json.encode({ type = 'user', uuid = sent.uuid, isReplay = true,
      parent_tool_use_id = vim.NIL, message = sent.message,
    }))
  ]])
  eq(_G.child.lua_get('_G._test_sent[1].type'), 'user')
  eq(_G.child.lua_get('_G._test_sent[1].message'), { role = 'user', content = 'hello from nvim' })
  eq(helpers.get_buffer_lines(_G.child), lines)
  eq(_G.child.lua_get('#_G._test_session.turns'), 0)
  eq(_G.child.lua_get('next(_G._test_session.sent_prompt_uuids) == nil'), true)
end

for _, flag in ipairs({ 'isSynthetic', 'isMeta' }) do
  T[flag .. ' prompt replay is ignored'] = function()
    setup_pipeline()
    local lines = helpers.get_buffer_lines(_G.child)
    _G.child.lua(([==[
      _G._test_feed(vim.json.encode({ type = 'user', isReplay = true, [%q] = true,
        uuid = 'foreign', message = { role = 'user', content = 'slash command output' },
      }))
    ]==]):format(flag))
    eq(helpers.get_buffer_lines(_G.child), lines)
    eq(_G.child.lua_get('#_G._test_session.turns'), 0)
    eq(_G.child.lua_get('_G._test_session.turn_active'), false)
  end
end

T['remote prompt content blocks render text and attachment placeholders'] = function()
  setup_pipeline()
  _G.child.lua([[
    _G._test_feed(vim.json.encode({ type = 'user', isReplay = true, uuid = 'foreign',
      message = { role = 'user', content = {
        { type = 'text', text = 'look at this' },
        { type = 'image', source = { type = 'base64', media_type = 'image/png', data = 'AAAA' } },
        { type = 'text', text = 'and this' },
        { type = 'document' },
      } },
    }))
  ]])
  assert_output('look at this')
  assert_output('[image]')
  assert_output('[document]')
  eq(_G.child.lua_get('_G._test_session.turns[1].text'), 'look at this\n[image]\nand this\n[document]')
end

T['empty prompt replays are ignored and attachment format is configurable'] = function()
  setup_pipeline()
  local lines = helpers.get_buffer_lines(_G.child)
  _G.child.lua([[
    for _, content in ipairs({ '', {} }) do
      _G._test_feed(vim.json.encode({ type = 'user', isReplay = true,
        message = { role = 'user', content = content },
      }))
    end
  ]])
  eq(helpers.get_buffer_lines(_G.child), lines)
  eq(_G.child.lua_get('#_G._test_session.turns'), 0)
  _G.child.lua([[
    require('cc.config').setup({ remote_control = { content_block_format = 'Attachment: %s' } })
    _G._test_feed(vim.json.encode({ type = 'user', isReplay = true,
      message = { role = 'user', content = { { type = 'image' } } },
    }))
  ]])
  assert_output('Attachment: image')
end

T['echoed permission control response with unknown request ID is a no-op'] = function()
  setup_pipeline()
  local lines = helpers.get_buffer_lines(_G.child)
  _G.child.lua([[
    _G._test_feed('{"type":"control_response","response":{"subtype":"success","request_id":"cli-generated","response":{"behavior":"allow"}}}')
  ]])
  eq(_G.child.lua_get('_G._test_sent'), {})
  eq(helpers.get_buffer_lines(_G.child), lines)
  eq(_G.child.lua_get('#_G._test_session.turns'), 0)
end

T['non-replay task notification still finishes a background task'] = function()
  setup_pipeline()
  _G.child.lua([[
    _G._test_session:begin_background_task('tool-1', 'task-1')
    _G._test_feed(vim.json.encode({ type = 'user', message = { role = 'user',
      content = '<task-notification><task-id>task-1</task-id><status>completed</status></task-notification>',
    } }))
  ]])
  eq(_G.child.lua_get('_G._test_session:background_task_count()'), 0)
  eq(_G.child.lua_get('#_G._test_session.turns'), 0)
end

T['process always spawns with prompt replay enabled'] = function()
  _G.child.lua([[
    local uv = vim.uv or vim.loop
    local spawn = uv.spawn
    uv.spawn = function(_, opts)
      _G._test_spawn_args = opts.args
      return nil, 'test spawn stopped'
    end
    local ok, err = pcall(function()
      require('cc.process').new({ cmd = '/unused/claude', on_message = function() end }):spawn()
    end)
    uv.spawn = spawn
    assert(not ok and err:find('test spawn stopped', 1, true))
  ]])
  eq(vim.tbl_contains(_G.child.lua_get('_G._test_spawn_args'), '--replay-user-messages'), true)
end

-- ---------------------------------------------------------------------------
-- Title sync: the cc.nvim session name is authoritative and the claude.ai
-- title follows it through the CLI's `rename_session` control request.
-- ---------------------------------------------------------------------------

T['process rename_session writes the host-sourced control request'] = function()
  setup_pipeline()
  _G.child.lua([[ _G._test_id = _G._test_process:rename_session('phone title') ]])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 1)
  eq(sent[1].type, 'control_request')
  eq(sent[1].request_id, _G.child.lua_get('_G._test_id'))
  eq(sent[1].request, { subtype = 'rename_session', title = 'phone title', source = 'host' })
end

T['rename_session fixture: success is silent, error renders and warns'] = function()
  setup_pipeline()
  _G.child.lua(([==[
    _G._test_fixture = vim.fn.readfile(%q)
    _G._test_results = {}
    local id = _G._test_process:rename_session('ok-title', function(ok, resp)
      table.insert(_G._test_results, { ok = ok, error = resp.error })
    end)
    _G._test_feed((_G._test_fixture[1]:gsub('RENAME_REQUEST_ID', id)))
    _G._test_lines_after_success = #vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false)
    local notify = vim.notify
    _G._test_notices = {}
    vim.notify = function(msg, level) table.insert(_G._test_notices, { msg = msg, level = level }) end
    id = _G._test_process:rename_session('   ', function(ok, resp)
      table.insert(_G._test_results, { ok = ok, error = resp.error })
    end)
    _G._test_feed((_G._test_fixture[2]:gsub('RENAME_REQUEST_ID', id)))
    vim.notify = notify
  ]==]):format(helpers.ndjson_fixtures_dir .. '/rename_session.ndjson'))
  eq(_G.child.lua_get('_G._test_results'), {
    { ok = true },
    { ok = false, error = 'title must be non-empty' },
  })
  eq(_G.child.lua_get('next(_G._test_process._pending_controls) == nil'), true)
  -- Success renders nothing: the CLI owns the record and the bridge push.
  eq(_G.child.lua_get('_G._test_lines_after_success'), 1)
  assert_output('Rename failed: title must be non-empty')
  eq(_G.child.lua_get('_G._test_notices'), {
    { msg = 'cc.nvim: Rename failed: title must be non-empty', level = vim.log.levels.WARN },
  })
end

T['rename error notice honors rename_error_format'] = function()
  setup_pipeline()
  _G.child.lua([[
    require('cc.config').setup({ remote_control = { rename_error_format = 'nope: %s' } })
    local notify = vim.notify
    vim.notify = function() end
    local id = _G._test_process:rename_session('x')
    _G._test_feed(vim.json.encode({ type = 'control_response', response = {
      subtype = 'error', request_id = id, error = 'session_id is not the current session',
    } }))
    vim.notify = notify
  ]])
  assert_output('nope: session_id is not the current session')
end

--- Register a live Claude instance backed by the stub process, then run
--- `body` (Lua source) with `inst` in scope and vim.notify captured.
local function with_live_claude(fields, body)
  _G.child.lua(([==[
    local P = require('cc.providers.claude')
    local provider = P.attach({ session = _G._test_session, output = _G._test_output })
    provider.process = _G._test_process
    local inst = vim.tbl_extend('force', {
      provider = provider, process = provider.process, session = _G._test_session,
      output = _G._test_output,
    }, %s)
    provider.instance = inst
    require('cc')._register_test_instance(_G._test_bufnr, inst)
    require('cc.commands').create()
    local notify = vim.notify
    _G._test_notices = {}
    vim.notify = function(msg, level) table.insert(_G._test_notices, { msg = msg, level = level }) end
    %s
    vim.notify = notify
  ]==]):format(fields, body))
end

T['CcRemote without a name enables with the session name'] = function()
  setup_pipeline()
  with_live_claude("{ session_name = 'cc-title-sync-named' }", [[
    vim.cmd('CcRemote')
    _G._test_session.remote_control_state = 'connected'
    vim.cmd('CcRemote')
    _G._test_session.remote_control_state = nil
    vim.cmd('CcRemote explicit')
  ]])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 3)
  eq(sent[1].request, { subtype = 'remote_control', enabled = true, name = 'cc-title-sync-named' })
  -- Disable never carries a name; an explicit argument still wins.
  eq(sent[2].request, { subtype = 'remote_control', enabled = false })
  eq(sent[3].request, { subtype = 'remote_control', enabled = true, name = 'explicit' })
end

T['CcRemote without a name uses a queued rename'] = function()
  setup_pipeline()
  with_live_claude("{ pending_session_name = 'queued-name' }", [[ vim.cmd('CcRemote') ]])
  eq(_G.child.lua_get('_G._test_sent[1].request'),
    { subtype = 'remote_control', enabled = true, name = 'queued-name' })
end

T['CcRemote without a name ignores the auto-rename placeholder'] = function()
  setup_pipeline()
  with_live_claude("{ pending_session_name = 'naming...', transient_rename_active = true }",
    [[ vim.cmd('CcRemote') ]])
  eq(_G.child.lua_get('_G._test_sent[1].request'), { subtype = 'remote_control', enabled = true })
end

T['live rename sends rename_session and leaves the transcript to the CLI'] = function()
  setup_pipeline()
  with_live_claude("{ last_session_id = 'cc-title-sync-sid' }", [[
    local history = require('cc.history')
    local append = history.append_custom_title
    _G._test_appends = 0
    history.append_custom_title = function() _G._test_appends = _G._test_appends + 1; return true end
    vim.cmd('CcRename cc-title-sync-live')
    -- Re-applying the current name pre-init must not pick up a -2 suffix.
    require('cc')._handle_rename(inst, 'cc-title-sync-live')
    history.append_custom_title = append
    _G._test_inst_name = inst.session_name
    _G._test_inst_pending = inst.pending_session_name
  ]])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 2)
  for _, msg in ipairs(sent) do
    eq(msg.request, { subtype = 'rename_session', title = 'cc-title-sync-live', source = 'host' })
  end
  eq(_G.child.lua_get('_G._test_appends'), 0)
  eq(_G.child.lua_get('_G._test_inst_name'), 'cc-title-sync-live')
  eq(_G.child.lua_get('_G._test_inst_pending == nil'), true)
  eq(_G.child.lua_get('_G._test_notices[1]'),
    { msg = 'cc.nvim: session renamed to "cc-title-sync-live"', level = vim.log.levels.INFO })
  eq(_G.child.lua_get(
    'vim.api.nvim_buf_get_name(_G._test_bufnr):match("cc%-cc%-title%-sync%-live$") ~= nil'), true)
end

T['dead Claude process falls back to the direct transcript write'] = function()
  setup_pipeline()
  with_live_claude("{ last_session_id = 'cc-title-sync-dead' }", [[
    _G._test_process.alive = false
    local history = require('cc.history')
    local path = vim.fn.tempname() .. '.jsonl'
    vim.fn.writefile({
      '{"type":"user","sessionId":"cc-title-sync-dead","message":{"role":"user","content":"seed"}}',
    }, path)
    local session_path = history.session_path
    history.session_path = function(sid) if sid == 'cc-title-sync-dead' then return path end end
    require('cc')._handle_rename(inst, 'cc-title-sync-offline')
    history.session_path = session_path
    local lines = vim.fn.readfile(path)
    _G._test_last = vim.json.decode(lines[#lines])
    _G._test_inst_name = inst.session_name
  ]])
  eq(_G.child.lua_get('#_G._test_sent'), 0)
  eq(_G.child.lua_get('_G._test_last'), {
    type = 'custom-title', customTitle = 'cc-title-sync-offline', sessionId = 'cc-title-sync-dead',
  })
  eq(_G.child.lua_get('_G._test_inst_name'), 'cc-title-sync-offline')
end

T['pending rename flushes through rename_session on a live process'] = function()
  setup_pipeline()
  with_live_claude("{ pending_session_name = 'cc-title-sync-queued', last_session_id = 'sid-q' }", [[
    require('cc')._flush_pending_rename(inst)
    _G._test_inst_name = inst.session_name
    _G._test_inst_pending = inst.pending_session_name
  ]])
  eq(_G.child.lua_get('_G._test_sent[1].request'),
    { subtype = 'rename_session', title = 'cc-title-sync-queued', source = 'host' })
  eq(_G.child.lua_get('_G._test_inst_name'), 'cc-title-sync-queued')
  eq(_G.child.lua_get('_G._test_inst_pending == nil'), true)
end

T['CcNew remote=name names the session, seeds the bridge, skips auto-rename'] = function()
  _G.child.lua([[
    require('cc.config').setup({ splash = false, statusline = { enabled = false } })
    local P = require('cc.providers.claude')
    local attach = P.attach
    _G._test_calls = {}
    P.attach = function(ctx)
      return {
        name = 'claude', capabilities = P.capabilities,
        spawn = function() table.insert(_G._test_calls, { 'remote_control', ctx.remote }) end,
        is_alive = function() return true end,
        close = function() end,
        rename_session = function(_, title)
          table.insert(_G._test_calls, { 'rename_session', title })
          return 'req-1'
        end,
      }
    end
    require('cc').open({ remote = 'cc-title-sync-phone' })
    P.attach = attach
    local inst = require('cc')._get_instance()
    _G._test_state = {
      session_name = inst.session_name,
      should_run = require('cc.auto_rename').should_run(inst),
      buf_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(inst.output.bufnr), ':t'),
    }
  ]])
  eq(_G.child.lua_get('_G._test_calls'), {
    { 'remote_control', 'cc-title-sync-phone' },
    { 'rename_session', 'cc-title-sync-phone' },
  })
  eq(_G.child.lua_get('_G._test_state'), {
    session_name = 'cc-title-sync-phone',
    should_run = false,
    buf_name = 'cc-cc-title-sync-phone',
  })
end

T['CcNew remote without a name leaves the session unnamed for auto-rename'] = function()
  _G.child.lua([[
    require('cc.config').setup({ splash = false, statusline = { enabled = false } })
    local P = require('cc.providers.claude')
    local attach = P.attach
    _G._test_renames = 0
    P.attach = function()
      return {
        name = 'claude', capabilities = P.capabilities,
        spawn = function() end, is_alive = function() return true end, close = function() end,
        rename_session = function() _G._test_renames = _G._test_renames + 1; return 'id' end,
      }
    end
    require('cc').open({ remote = true })
    P.attach = attach
    local inst = require('cc')._get_instance()
    _G._test_state = {
      session_name = inst.session_name, should_run = require('cc.auto_rename').should_run(inst),
    }
  ]])
  eq(_G.child.lua_get('_G._test_renames'), 0)
  eq(_G.child.lua_get('_G._test_state'), { should_run = true })
end

return T
