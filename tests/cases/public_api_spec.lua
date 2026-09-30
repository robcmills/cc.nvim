-- Public API for external agent control: open(opts) with focus/cwd/name/
-- prompt, send_prompt, get_last_assistant_message, stop(bufnr), close(bufnr). Everything
-- here must work over `nvim --remote-expr`, so return values matter more
-- than notifications.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

--- Replace the claude provider module with an in-process fake so `open`
--- runs the real create_instance/attach_provider path without a subprocess.
--- The fake records sends on `_G._fake_provider.sent`.
local INSTALL_FAKE = [==[
  _G._orig_claude = package.loaded['cc.providers.claude']
  local fake = { name = 'claude', capabilities = { auto_rename = false } }
  fake.options = function() return {} end
  fake.attach = function(ctx)
    local p = {
      name = 'claude', capabilities = fake.capabilities, opts = { cwd = ctx.cwd },
      alive = true, sent = {}, ctx = ctx, pid = 4242,
    }
    function p:spawn() end
    function p:is_alive() return self.alive end
    function p:close() self.alive = false end
    function p:send(text) table.insert(self.sent, text) end
    p.interrupts = 0
    function p:interrupt()
      self.interrupts = self.interrupts + 1
      return self.interrupt_result ~= false
    end
    _G._fake_provider = p
    return p
  end
  package.loaded['cc.providers.claude'] = fake
  require('cc.config').setup({})
]==]

local RESTORE_FAKE = [==[
  package.loaded['cc.providers.claude'] = _G._orig_claude
]==]

T['open'] = MiniTest.new_set()

T['open']['focus=false creates a hidden listed instance without touching the current window'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    vim.cmd('enew')
    local before_buf = vim.api.nvim_get_current_buf()
    local before_win = vim.api.nvim_get_current_win()
    local before_wins = #vim.api.nvim_list_wins()
    local cwd = vim.fn.getcwd() .. '/tests'
    _G._name = 'api-spec-' .. tostring(vim.uv.hrtime())
    local bufnr, err = cc.open({
      focus = false, cwd = cwd, name = _G._name,
      prompt = 'Reply with the single word pong',
    })
    _G._r = {
      bufnr = bufnr, err = err,
      same_buf = vim.api.nvim_get_current_buf() == before_buf,
      same_win = vim.api.nvim_get_current_win() == before_win,
      same_win_count = #vim.api.nvim_list_wins() == before_wins,
      listed = vim.bo[bufnr].buflisted,
      hidden = vim.fn.bufwinid(bufnr) == -1,
      mode = vim.fn.mode(),
      sent = _G._fake_provider.sent,
      provider_cwd = _G._fake_provider.ctx.cwd,
      expected_cwd = cwd,
      snapshots = cc.list_instances(),
      output_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(type(r.bufnr), 'number')
  eq(r.err, nil)
  eq(r.same_buf, true)
  eq(r.same_win, true)
  eq(r.same_win_count, true)
  eq(r.listed, true)
  eq(r.hidden, true)
  eq(r.mode, 'n')
  eq(r.sent, { 'Reply with the single word pong' })
  eq(r.provider_cwd, r.expected_cwd)
  eq(#r.snapshots, 1)
  eq(r.snapshots[1].outputBufnr, r.bufnr)
  eq(r.snapshots[1].name, _G.child.lua_get('_G._name'))
  eq(r.snapshots[1].cwd, r.expected_cwd)
  eq(r.snapshots[1].state, 'working')
  eq(vim.tbl_contains(r.output_lines, 'User:'), true)
end

T['open']['default focus still lays out output + prompt windows'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    vim.cmd('enew')
    local bufnr = cc.open()
    local inst = cc.find_instance(bufnr)
    _G._r = {
      bufnr = bufnr,
      current_is_prompt = vim.api.nvim_get_current_buf() == inst.prompt.bufnr,
      output_visible = vim.fn.bufwinid(bufnr) ~= -1,
      sent = _G._fake_provider.sent,
    }
    vim.cmd('stopinsert')
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(type(r.bufnr), 'number')
  eq(r.current_is_prompt, true)
  eq(r.output_visible, true)
  eq(r.sent, {})
end

T['open']['returns nil, err and registers nothing on bad input'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local b1, e1 = cc.open({ focus = false, provider = 'nope' })
    local b2, e2 = cc.open({ focus = false, cwd = '/definitely/not/a/dir' })
    local b3, e3 = cc.open({ focus = false, effort = 'ludicrous' })
    local b4, e4 = cc.open({ focus = false, prompt = '   ' })
    _G._r = {
      b1 = b1, e1 = e1, b2 = b2, e2 = e2, b3 = b3, e3 = e3, b4 = b4, e4 = e4,
      count = #cc.list_instances(),
    }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.b1, nil)
  eq(r.e1:find('unknown provider', 1, true) ~= nil, true)
  eq(r.b2, nil)
  eq(r.e2:find('not a directory', 1, true) ~= nil, true)
  eq(r.b3, nil)
  eq(r.e3:find('invalid effort', 1, true) ~= nil, true)
  eq(r.b4, nil)
  eq(r.e4:find('non%-empty') ~= nil, true)
  eq(r.count, 0)
end

T['open']['focus=false drops the instance when the provider fails to spawn'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local fake = package.loaded['cc.providers.claude']
    local orig_attach = fake.attach
    fake.attach = function(ctx)
      local p = orig_attach(ctx)
      p.spawn = function() error('spawn exploded') end
      return p
    end
    local bufnr, err = cc.open({ focus = false })
    _G._r = { bufnr = bufnr, err = err, count = #cc.list_instances() }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.bufnr, nil)
  eq(r.err:find('spawn exploded', 1, true) ~= nil, true)
  eq(r.count, 0)
end

T['send_prompt'] = MiniTest.new_set()

T['send_prompt']['refuses mid-turn, then forwards once the turn finishes'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local bufnr = cc.open({ focus = false, prompt = 'first' })
    local inst = cc.find_instance(bufnr)
    local ok1, err1 = cc.send_prompt(bufnr, 'second')
    inst.session:finish_turn()
    local ok2, err2 = cc.send_prompt(bufnr, 'second')
    inst.session:finish_turn()
    -- The prompt bufnr identifies the instance too.
    local ok3, err3 = cc.send_prompt(inst.prompt.bufnr, 'third')
    local ok4, err4 = cc.send_prompt(99999, 'nobody home')
    inst.session:finish_turn()
    local ok5, err5 = cc.send_prompt(bufnr, '')
    _G._r = {
      ok1 = ok1, err1 = err1, ok2 = ok2, err2 = err2, ok3 = ok3, err3 = err3,
      ok4 = ok4, err4 = err4, ok5 = ok5, err5 = err5,
      sent = _G._fake_provider.sent,
      turns = #inst.session.turns,
      state = require('cc.instance_state').get(inst),
    }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.ok1, false)
  eq(r.err1:find('turn in progress', 1, true) ~= nil, true)
  eq(r.ok2, true)
  eq(r.err2, nil)
  eq(r.ok3, true)
  eq(r.err3, nil)
  eq(r.ok4, false)
  eq(r.err4:find('no cc.nvim instance owns buffer 99999', 1, true) ~= nil, true)
  eq(r.ok5, false)
  eq(r.err5:find('non%-empty') ~= nil, true)
  eq(r.sent, { 'first', 'second', 'third' })
  eq(r.turns, 3)
  -- A finished turn in a hidden instance nobody has viewed is `unread`, not
  -- `ready`; external pollers must accept both as "idle".
  eq(r.state, 'unread')
end

T['send_prompt']['refuses a dead process'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local bufnr = cc.open({ focus = false })
    _G._fake_provider.alive = false
    local ok, err = cc.send_prompt(bufnr, 'hello?')
    _G._r = { ok = ok, err = err }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.ok, false)
  eq(r.err:find('not open', 1, true) ~= nil, true)
end

T['send_prompt']['handles client-side slash commands without forwarding'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local bufnr = cc.open({ focus = false })
    local name = 'api-slash-' .. tostring(vim.uv.hrtime())
    local ok, err = cc.send_prompt(bufnr, '/rename ' .. name)
    _G._r = {
      ok = ok, err = err, sent = _G._fake_provider.sent,
      name = cc.list_instances()[1].name, expected = name,
    }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.ok, true)
  eq(r.err, nil)
  eq(r.sent, {})
  eq(r.name, r.expected)
end

T['send_prompt']['prompt-buffer submit still clears the prompt on success only'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local bufnr = cc.open()
    vim.cmd('stopinsert')
    local inst = cc.find_instance(bufnr)
    vim.api.nvim_set_current_buf(inst.prompt.bufnr)
    vim.api.nvim_buf_set_lines(inst.prompt.bufnr, 0, -1, false, { 'typed' })
    cc.submit()
    local after_first = vim.api.nvim_buf_get_lines(inst.prompt.bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(inst.prompt.bufnr, 0, -1, false, { 'while busy' })
    cc.submit()
    local after_second = vim.api.nvim_buf_get_lines(inst.prompt.bufnr, 0, -1, false)
    _G._r = { after_first = after_first, after_second = after_second, sent = _G._fake_provider.sent }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.after_first, { '' })
  eq(r.after_second, { 'while busy' })
  eq(r.sent, { 'typed' })
end

T['get_last_assistant_message'] = MiniTest.new_set()

T['get_last_assistant_message']['claude: last text-bearing message, skipping tool-only ones'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local bufnr = cc.open({ focus = false, prompt = 'ping' })
    local inst = cc.find_instance(bufnr)
    local s = inst.session
    local t0, e0 = cc.get_last_assistant_message(bufnr)
    -- Streamed reply, as the router drives it.
    s:begin_message({ id = 'm1', role = 'assistant' })
    s:begin_block(0, { type = 'text', text = '' })
    s:apply_delta(0, { type = 'text_delta', text = 'po' })
    s:apply_delta(0, { type = 'text_delta', text = 'ng' })
    s:end_block(0)
    s:begin_block(1, { type = 'text', text = '' })
    s:apply_delta(1, { type = 'text_delta', text = 'second block' })
    s:end_block(1)
    s:end_message()
    local t1, e1 = cc.get_last_assistant_message(bufnr)
    -- A trailing tool-only message must not hide the reply.
    s:begin_message({ id = 'm2', role = 'assistant' })
    s:begin_block(0, { type = 'tool_use', id = 'tu1', name = 'Bash' })
    s:end_block(0)
    s:end_message()
    local t2 = cc.get_last_assistant_message(inst.prompt.bufnr)
    local t3, e3 = cc.get_last_assistant_message(99999)
    _G._r = { t0 = t0, e0 = e0, t1 = t1, e1 = e1, t2 = t2, t3 = t3, e3 = e3 }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.t0, nil)
  eq(r.e0, 'no assistant message yet')
  eq(r.t1, 'pong\n\nsecond block')
  eq(r.e1, nil)
  eq(r.t2, 'pong\n\nsecond block')
  eq(r.t3, nil)
  eq(r.e3:find('no cc.nvim instance owns buffer', 1, true) ~= nil, true)
end

T['get_last_assistant_message']['codex: completed agentMessage items are recorded'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local cc = require('cc')
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-public-api-codex')
    local output_bufnr = output:ensure_buffer()
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local instance = {
      session = session, output = output,
      prompt = { bufnr = prompt_bufnr }, awaiting_input = false,
    }
    local provider = require('cc.providers.codex').attach({
      instance = instance, session = session, output = output,
    })
    provider.alive = true
    provider._write_line = function() end
    instance.provider = provider
    instance.process = provider
    cc._register_test_instance(output_bufnr, instance)

    local t0 = cc.get_last_assistant_message(output_bufnr)
    -- Streamed path: start, deltas, then the authoritative completed item.
    provider:_on_item_started({ type = 'agentMessage', id = 'a1' })
    provider:_on_text_delta('a1', 'po', 'text')
    provider:_on_text_delta('a1', 'ng', 'text')
    provider:_on_item_completed({ type = 'agentMessage', id = 'a1', text = 'pong' })
    local t1 = cc.get_last_assistant_message(output_bufnr)
    -- Completed without a start (instant item) still counts.
    provider:_on_item_completed({ type = 'agentMessage', id = 'a2', text = 'pong again' })
    local t2 = cc.get_last_assistant_message(output_bufnr)
    _G._r = { t0 = t0, t1 = t1, t2 = t2 }
  ]==])
  local r = _G.child.lua_get('_G._r')
  eq(r.t0, nil)
  eq(r.t1, 'pong')
  eq(r.t2, 'pong again')
end

T['stop'] = MiniTest.new_set()

T['stop']['interrupts a target instance by output or prompt bufnr'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    vim.cmd('enew')
    local scratch = vim.api.nvim_get_current_buf()
    local a = cc.open({ focus = false })
    local a_provider = _G._fake_provider
    local b = cc.open({ focus = false })
    local b_provider = _G._fake_provider
    local a_inst, b_inst = cc.find_instance(a), cc.find_instance(b)
    local r = {}
    r.idle = { cc.stop(a) }
    a_inst.session.turn_active = true
    b_inst.session.turn_active = true
    r.first = { cc.stop(a) }
    r.pending_flag = a_inst.session.interrupt_pending
    r.again = { cc.stop(a) }
    r.by_prompt = { cc.stop(b_inst.prompt.bufnr) }
    r.missing = { cc.stop(scratch) }
    r.not_number = { cc.stop('x') }
    r.current = { cc.stop() }
    r.a_interrupts = a_provider.interrupts
    r.b_interrupts = b_provider.interrupts
    b_inst.session.interrupt_pending = false
    b_provider.interrupt_result = false
    r.unsent = { cc.stop(b) }
    r.unsent_flag = b_inst.session.interrupt_pending
    b_provider.alive = false
    r.dead = { cc.stop(b) }
    r.still_on_scratch = vim.api.nvim_get_current_buf() == scratch
    _G._r = r
    b_provider.alive = true
    cc.close(a); cc.close(b)
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.idle, { false, 'no turn active' })
  eq(r.first, { true })
  eq(r.pending_flag, true)
  eq(r.again, { false, 'interrupt already pending' })
  eq(r.by_prompt, { true })
  eq(r.missing[1], false)
  eq(r.missing[2]:find('no cc.nvim instance owns buffer', 1, true) ~= nil, true)
  eq(r.not_number[1], false)
  eq(r.current, { false, 'current buffer is not a cc.nvim buffer' })
  eq(r.a_interrupts, 1)
  eq(r.b_interrupts, 1)
  eq(r.unsent, { false, 'interrupt could not be sent' })
  eq(r.unsent_flag, false)
  eq(r.dead, { false, 'agent process is not running' })
  eq(r.still_on_scratch, true)
end

T['stop']['without an argument interrupts the current instance'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local bufnr = cc.open()
    vim.cmd('stopinsert')
    cc.find_instance(bufnr).session.turn_active = true
    local ok, err = cc.stop()
    _G._r = { ok = ok, err = err, interrupts = _G._fake_provider.interrupts }
    cc.close(bufnr)
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.ok, true)
  eq(r.err, nil)
  eq(r.interrupts, 1)
end

T['close'] = MiniTest.new_set()

T['close']['closes a target instance by output or prompt bufnr'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    vim.cmd('enew')
    local scratch = vim.api.nvim_get_current_buf()
    local a = cc.open({ focus = false })
    local a_provider = _G._fake_provider
    local a_prompt = cc.find_instance(a).prompt.bufnr
    local b = cc.open({ focus = false })
    local b_prompt = cc.find_instance(b).prompt.bufnr
    local ok_a, err_a = cc.close(a)
    local after_a = #cc.list_instances()
    local ok_b, err_b = cc.close(b_prompt)
    local ok_missing, err_missing = cc.close(a)
    local ok_current, err_current = cc.close()
    _G._r = {
      ok_a = ok_a, err_a = err_a, after_a = after_a,
      ok_b = ok_b, err_b = err_b,
      ok_missing = ok_missing, err_missing = err_missing,
      ok_current = ok_current, err_current = err_current,
      a_alive = a_provider.alive,
      a_valid = vim.api.nvim_buf_is_valid(a),
      a_prompt_valid = vim.api.nvim_buf_is_valid(a_prompt),
      b_valid = vim.api.nvim_buf_is_valid(b),
      remaining = #cc.list_instances(),
      still_on_scratch = vim.api.nvim_get_current_buf() == scratch,
    }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.ok_a, true)
  eq(r.err_a, nil)
  eq(r.after_a, 1)
  eq(r.ok_b, true)
  eq(r.err_b, nil)
  eq(r.ok_missing, false)
  eq(r.err_missing:find('no cc.nvim instance owns buffer', 1, true) ~= nil, true)
  eq(r.ok_current, false)
  eq(r.err_current:find('not a cc.nvim buffer', 1, true) ~= nil, true)
  eq(r.a_alive, false)
  eq(r.a_valid, false)
  eq(r.a_prompt_valid, false)
  eq(r.b_valid, false)
  eq(r.remaining, 0)
  eq(r.still_on_scratch, true)
end

T['close']['without an argument closes the current instance'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    local bufnr = cc.open()
    vim.cmd('stopinsert')
    local ok, err = cc.close()
    _G._r = { ok = ok, err = err, remaining = #cc.list_instances(), valid = vim.api.nvim_buf_is_valid(bufnr) }
  ]==] .. RESTORE_FAKE)
  local r = _G.child.lua_get('_G._r')
  eq(r.ok, true)
  eq(r.err, nil)
  eq(r.remaining, 0)
  eq(r.valid, false)
end

return T
