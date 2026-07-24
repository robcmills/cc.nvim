-- Process-level integration: spawn fake_codex.sh in place of the codex CLI
-- and exercise the full pipeline — uv.spawn, pipes, JSON-RPC handshake,
-- request correlation, turn streaming, and teardown.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local FAKE_CODEX = helpers.repo_root .. '/tests/fixtures/fake_codex.sh'

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Attach + spawn a codex provider against fake_codex.sh and wait for the
--- thread to be ready.
---@param resume_id string?
local function spawn_fake_codex(child, resume_id)
  child.lua(string.format([==[
    require('cc.config').setup({
      provider = 'codex',
      providers = { codex = { cmd = %q } },
    })
    local Session = require('cc.session')
    local Output = require('cc.output')
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local inst = { session = session, output = output }
    local got_session_id = nil
    local provider = require('cc.providers.codex').attach({
      instance = inst,
      session = session,
      output = output,
      resume_id = %s,
      on_session_id = function(id) got_session_id = id end,
    })
    inst.provider = provider
    inst.process = provider
    provider:spawn()
    vim.wait(10000, function() return got_session_id ~= nil end, 10)

    _G._test_bufnr = bufnr
    _G._test_session = session
    _G._test_output = output
    _G._test_provider = provider
    _G._test_session_id = got_session_id
  ]==], FAKE_CODEX, resume_id and string.format('%q', resume_id) or 'nil'))
end

local function buffer_text(child)
  return table.concat(
    child.lua_get('vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false)'), '\n')
end

T['handshake completes and seeds the session'] = function()
  spawn_fake_codex(_G.child)
  eq(_G.child.lua_get('_G._test_session_id'), 'thread-1')
  eq(_G.child.lua_get('_G._test_session.model'), 'gpt-test')
  eq(_G.child.lua_get('_G._test_provider:is_alive()'), true)
  _G.child.lua('_G._test_provider:close()')
end

T['full turn streams text, tool call, usage, and completion'] = function()
  spawn_fake_codex(_G.child)
  _G.child.lua([==[
    _G._test_session:add_user_turn('hi')
    _G._test_output:render_user_turn('hi')
    _G._test_provider:send('hi')
    vim.wait(10000, function() return _G._test_session.turn_active == false end, 10)
  ]==])
  eq(_G.child.lua_get('_G._test_session.turn_active'), false)
  local text = buffer_text(_G.child)
  eq(text:find('hello from fake codex', 1, true) ~= nil, true)
  eq(text:find('Bash: echo fake', 1, true), nil)
  eq(text:find('Bash:', 1, true) ~= nil, true)
  eq(text:find('\n    echo fake', 1, true) ~= nil, true)
  eq(text:find('      fake', 1, true) ~= nil, true)
  eq(text:find('10 out', 1, true) ~= nil, true) -- turn cost line
  eq(_G.child.lua_get('_G._test_session.output_tokens'), 10)
  eq(_G.child.lua_get('_G._test_session.cache_read_input_tokens'), 40)
  _G.child.lua('_G._test_provider:close()')
end

T['resume replays stored turns'] = function()
  spawn_fake_codex(_G.child, 'thread-1')
  local text = buffer_text(_G.child)
  eq(text:find('stored prompt', 1, true) ~= nil, true)
  eq(text:find('stored reply', 1, true) ~= nil, true)
  _G.child.lua('_G._test_provider:close()')
end

T['close terminates the subprocess'] = function()
  spawn_fake_codex(_G.child)
  _G.child.lua([==[
    local exited = false
    _G._test_provider.on_exit = function() exited = true end
    _G._test_provider:close()
    vim.wait(5000, function() return exited end, 10)
    _G._test_exited = exited
    _G._test_alive = _G._test_provider:is_alive()
  ]==])
  eq(_G.child.lua_get('_G._test_alive'), false)
  eq(_G.child.lua_get('_G._test_exited'), true)
end

return T
