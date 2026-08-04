-- Tests for lua/cc/permission_prompt.lua — the floating-window permission
-- prompt that replaces vim.ui.select for can_use_tool requests.

local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

local float_state

local function open(child, lua_args)
  child.lua(([==[
    _G._test_choice = nil
    require('cc.config').setup({})
    require('cc.permission_prompt').ask(%s, function(behavior, variant)
      _G._test_choice = { behavior = behavior, variant = variant }
    end)
  ]==]):format(lua_args))
end

T['configured callback receives session and tool context once'] = function()
  _G.child.lua([==[
    local output_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(output_bufnr, 'cc-notification-session')
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local count = 0
    require('cc.config').setup({
      on_permission_prompt = function(event)
        count = count + 1
        _G._test_event = event
        _G._test_callback_count = count
      end,
    })
    require('cc.permission_prompt').ask(
      'Bash',
      { command = 'make test' },
      function() end,
      {
        provider = 'codex',
        instance = {
          session = { id = 'session-from-state' },
          last_session_id = 'session-123',
          session_name = 'notification-session',
          output = { bufnr = output_bufnr },
          prompt = { bufnr = prompt_bufnr },
        },
      }
    )
  ]==])

  local event = _G.child.lua_get('_G._test_event')
  eq(_G.child.lua_get('_G._test_callback_count'), 1)
  eq(event.provider, 'codex')
  eq(event.session_id, 'session-123')
  eq(event.session_name, 'notification-session')
  eq(event.output_bufname, 'cc-notification-session')
  eq(event.tool_name, 'Bash')
  eq(event.input.command, 'make test')
  eq(type(event.output_bufnr), 'number')
  eq(type(event.prompt_bufnr), 'number')
end

T['callback errors do not prevent the permission prompt from opening'] = function()
  _G.child.lua([==[
    _G._test_notified_error = nil
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if msg:find('on_permission_prompt callback failed', 1, true) then
        _G._test_notified_error = { msg = msg, level = level }
      else
        original_notify(msg, level)
      end
    end
    require('cc.config').setup({
      on_permission_prompt = function() error('notification exploded') end,
    })
    _G._test_ask_ok = pcall(function()
      require('cc.permission_prompt').ask(
        'Bash', { command = 'true' }, function() end,
        { provider = 'claude' })
    end)
    vim.notify = original_notify
  ]==])

  eq(_G.child.lua_get('_G._test_ask_ok'), true)
  local notified = _G.child.lua_get('_G._test_notified_error')
  eq(notified.msg:find('notification exploded', 1, true) ~= nil, true)
  eq(notified.level, vim.log.levels.ERROR)
  eq(float_state(_G.child) ~= vim.NIL, true)
end

float_state = function(child)
  return child.lua_get([[
    (function()
      local wins = vim.api.nvim_list_wins()
      for _, w in ipairs(wins) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative ~= '' then
          local buf = vim.api.nvim_win_get_buf(w)
          return {
            winid = w,
            bufnr = buf,
            title = type(cfg.title) == 'table' and cfg.title[1][1] or cfg.title,
            footer = type(cfg.footer) == 'table' and cfg.footer[1][1] or cfg.footer,
            lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
            filetype = vim.bo[buf].filetype,
          }
        end
      end
      return nil
    end)()
  ]])
end

T['Bash command shown as buffer content'] = function()
  open(_G.child, [[
    'Bash',
    { command = 'ls -la /tmp\necho hi', description = 'list tmp' }
  ]])
  local s = float_state(_G.child)
  eq(s.lines, { 'ls -la /tmp', 'echo hi' })
  eq(s.filetype, 'bash')
end

T['title includes tool name and description'] = function()
  open(_G.child, [[
    'Bash',
    { command = 'true', description = 'sanity check' }
  ]])
  local s = float_state(_G.child)
  -- Title is wrapped in spaces; the rendered text from nvim_win_get_config
  -- preserves them.
  if not s.title:find('Bash', 1, true) then
    error('title missing tool name: ' .. tostring(s.title))
  end
  if not s.title:find('sanity check', 1, true) then
    error('title missing description: ' .. tostring(s.title))
  end
end

T['title falls back to summarized input when no description'] = function()
  open(_G.child, [[
    'Read',
    { file_path = '/home/me/notes.md' }
  ]])
  local s = float_state(_G.child)
  if not s.title:find('Read', 1, true) then
    error('title missing tool name: ' .. tostring(s.title))
  end
  if not s.title:find('/home/me/notes.md', 1, true) then
    error('title missing file path summary: ' .. tostring(s.title))
  end
end

T['footer shows key hints'] = function()
  open(_G.child, [[ 'Bash', { command = 'true' } ]])
  local s = float_state(_G.child)
  for _, frag in ipairs({ '[a]llow', '[A]lways', '[d]eny', 'cancel' }) do
    if not s.footer:find(frag, 1, true) then
      error('footer missing fragment ' .. frag .. ': ' .. tostring(s.footer))
    end
  end
end

T['pressing a resolves allow_once and closes window'] = function()
  open(_G.child, [[ 'Bash', { command = 'true' } ]])
  _G.child.type_keys('a')
  -- Resolution is scheduled; let it settle.
  _G.child.lua([[vim.wait(50, function() return _G._test_choice ~= nil end)]])
  eq(_G.child.lua_get('_G._test_choice.behavior'), 'allow')
  eq(_G.child.lua_get('_G._test_choice.variant'), 'allow_once')
  -- No floats remain.
  eq(float_state(_G.child), vim.NIL)
end

T['pressing A resolves allow_always'] = function()
  open(_G.child, [[ 'Bash', { command = 'true' } ]])
  _G.child.type_keys('A')
  _G.child.lua([[vim.wait(50, function() return _G._test_choice ~= nil end)]])
  eq(_G.child.lua_get('_G._test_choice.behavior'), 'allow')
  eq(_G.child.lua_get('_G._test_choice.variant'), 'allow_always')
end

T['pressing d resolves deny'] = function()
  open(_G.child, [[ 'Bash', { command = 'true' } ]])
  _G.child.type_keys('d')
  _G.child.lua([[vim.wait(50, function() return _G._test_choice ~= nil end)]])
  eq(_G.child.lua_get('_G._test_choice.behavior'), 'deny')
  eq(_G.child.lua_get('_G._test_choice.variant'), 'deny')
end

T['pressing q resolves deny (cancel)'] = function()
  open(_G.child, [[ 'Bash', { command = 'true' } ]])
  _G.child.type_keys('q')
  _G.child.lua([[vim.wait(50, function() return _G._test_choice ~= nil end)]])
  eq(_G.child.lua_get('_G._test_choice.behavior'), 'deny')
  eq(_G.child.lua_get('_G._test_choice.variant'), 'cancel')
end

T['Edit input renders as a diff'] = function()
  open(_G.child, [[
    'Edit',
    {
      file_path = '/tmp/x.txt',
      old_string = 'foo',
      new_string = 'bar',
    }
  ]])
  local s = float_state(_G.child)
  eq(s.filetype, 'diff')
  -- After indent-strip, +/- markers sit at column 0.
  local has_minus, has_plus = false, false
  for _, line in ipairs(s.lines) do
    if line:sub(1, 1) == '-' and line:find('foo', 1, true) then has_minus = true end
    if line:sub(1, 1) == '+' and line:find('bar', 1, true) then has_plus = true end
  end
  eq(has_minus, true)
  eq(has_plus, true)
end

T['unknown tool falls back to YAML body'] = function()
  open(_G.child, [[
    'mcp__example__do_thing',
    { hello = 'world', n = 42 }
  ]])
  local s = float_state(_G.child)
  local joined = table.concat(s.lines, '\n')
  if not joined:find('hello: world', 1, true) then
    error('body missing hello: world — got:\n' .. joined)
  end
  if not joined:find('n: 42', 1, true) then
    error('body missing n: 42 — got:\n' .. joined)
  end
end

return T
