-- Tests for /rename: client-side interception, custom-title persistence,
-- and read-back through history metadata.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

--- Write a minimal transcript to a temp file and return its path.
local function write_fixture(child, session_id, extra_records)
  return child.lua_get(string.format([[(function()
    local tmp = vim.fn.tempname() .. '.jsonl'
    local f = io.open(tmp, 'w')
    f:write(vim.json.encode({
      type = 'user',
      sessionId = %q,
      cwd = '/tmp/cc-rename-test',
      message = { role = 'user', content = 'hello world' },
    }) .. '\n')
    %s
    f:close()
    return tmp
  end)()]], session_id, extra_records or ''))
end

-- ---------------------------------------------------------------------------
-- history.append_custom_title
-- ---------------------------------------------------------------------------
T['append_custom_title'] = MiniTest.new_set()

T['append_custom_title']['writes a custom-title JSONL record'] = function()
  local path = write_fixture(_G.child, 'abc-123')
  local ok = _G.child.lua_get(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', 'my session')",
    path))
  eq(ok, true)
  local lines = _G.child.lua_get(string.format('vim.fn.readfile(%q)', path))
  -- Parse the last line: should be {type='custom-title',customTitle='my session',sessionId='abc-123'}
  local last = lines[#lines]
  local rec = _G.child.lua_get(string.format('vim.json.decode(%q)', last))
  eq(rec.type, 'custom-title')
  eq(rec.customTitle, 'my session')
  eq(rec.sessionId, 'abc-123')
end

T['append_custom_title']['appends without truncating existing records'] = function()
  local path = write_fixture(_G.child, 'abc-123')
  local before = _G.child.lua_get(string.format('#vim.fn.readfile(%q)', path))
  _G.child.lua(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', 'name-1')", path))
  _G.child.lua(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', 'name-2')", path))
  local after = _G.child.lua_get(string.format('#vim.fn.readfile(%q)', path))
  eq(after, before + 2)
end

-- ---------------------------------------------------------------------------
-- history._extract_metadata / list entries
-- ---------------------------------------------------------------------------
T['extract_metadata'] = MiniTest.new_set()

T['extract_metadata']['picks up latest customTitle'] = function()
  local path = write_fixture(_G.child, 'abc-123')
  _G.child.lua(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', 'first')", path))
  _G.child.lua(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', 'second')", path))
  local meta = _G.child.lua_get(string.format(
    "require('cc.history')._extract_metadata(%q)", path))
  eq(meta.custom_title, 'second')
end

T['extract_metadata']['falls back to first user message'] = function()
  local path = write_fixture(_G.child, 'abc-123')
  local meta = _G.child.lua_get(string.format(
    "require('cc.history')._extract_metadata(%q)", path))
  eq(meta.custom_title, nil)
  eq(meta.first_prompt, 'hello world')
end

T['extract_metadata']['empty customTitle clears previous'] = function()
  local path = write_fixture(_G.child, 'abc-123')
  _G.child.lua(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', 'named')", path))
  _G.child.lua(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', '')", path))
  local meta = _G.child.lua_get(string.format(
    "require('cc.history')._extract_metadata(%q)", path))
  eq(meta.custom_title, nil)
end

T['extract_metadata']['read_session_meta surfaces custom_title'] = function()
  local path = write_fixture(_G.child, 'abc-123')
  _G.child.lua(string.format(
    "require('cc.history').append_custom_title(%q, 'abc-123', 'renamed')", path))
  local meta = _G.child.lua_get(string.format(
    "require('cc.history').read_session_meta(%q)", path))
  eq(meta.custom_title, 'renamed')
end

-- ---------------------------------------------------------------------------
-- slash command completion
-- ---------------------------------------------------------------------------
T['slash_completion'] = MiniTest.new_set()

T['slash_completion']['includes /rename'] = function()
  local names = _G.child.lua_get([[(function()
    local list = require('cc.slash').list({})
    local out = {}
    for _, cmd in ipairs(list) do table.insert(out, cmd.name) end
    return out
  end)()]])
  local has_rename = false
  for _, n in ipairs(names) do
    if n == 'rename' then has_rename = true; break end
  end
  eq(has_rename, true)
end

-- ---------------------------------------------------------------------------
-- /rename dispatch in submit()
-- ---------------------------------------------------------------------------
T['dispatch'] = MiniTest.new_set()

T['dispatch']['handler parses name and sets instance.session_name'] = function()
  local result = _G.child.lua_get([[(function()
    -- Arrange a fake instance with writer + session dir.
    local tmp_project = vim.fn.tempname()
    vim.fn.mkdir(tmp_project, 'p')
    local session_id = 'ffffffff-1111-2222-3333-444444444444'
    local path = tmp_project .. '/' .. session_id .. '.jsonl'
    local f = io.open(path, 'w')
    f:write(vim.json.encode({ type='user', sessionId=session_id,
      cwd=vim.fn.getcwd(), message={role='user',content='seed'} }) .. '\n')
    f:close()

    -- Monkey-patch history.session_path to return our tmp path.
    local history = require('cc.history')
    local orig = history.session_path
    history.session_path = function(sid) if sid == session_id then return path end end

    local notices = {}
    local orig_notify = vim.notify
    vim.notify = function(text, _level) table.insert(notices, text) end
    local prompt_name_calls = {}
    local inst = {
      last_session_id = session_id,
      session_name = nil,
      session = {},
      output = {},
      prompt = {
        set_buf_name = function(self, name) table.insert(prompt_name_calls, name) end,
      },
    }

    local cc = require('cc')
    cc._handle_rename(inst, 'my-new-name')

    history.session_path = orig
    vim.notify = orig_notify
    local lines = vim.fn.readfile(path)
    local last_rec = vim.json.decode(lines[#lines])
    return {
      session_name = inst.session_name,
      notice = notices[1],
      last_type = last_rec.type,
      last_title = last_rec.customTitle,
      prompt_name = prompt_name_calls[1],
    }
  end)()]])
  eq(result.session_name, 'my-new-name')
  eq(result.last_type, 'custom-title')
  eq(result.last_title, 'my-new-name')
  eq(result.notice, 'cc.nvim: session renamed to "my-new-name"')
  eq(result.prompt_name, 'cc-my-new-name')
end

T['dispatch']['empty args prints usage'] = function()
  local notice = _G.child.lua_get([[(function()
    local notices = {}
    local orig_notify = vim.notify
    vim.notify = function(text, _level) table.insert(notices, text) end
    local inst = {
      last_session_id = 'abc',
      session_name = nil,
      session = {},
      output = {},
    }
    require('cc')._handle_rename(inst, '')
    vim.notify = orig_notify
    return notices[1]
  end)()]])
  local ok = notice and notice:match('usage') ~= nil
  eq(ok, true)
end

T['dispatch']['try_handle matches /rename'] = function()
  local handled = _G.child.lua_get([[(function()
    local orig_notify = vim.notify
    vim.notify = function() end
    local inst = {
      last_session_id = nil,
      session = {},
      output = {},
    }
    local result = require('cc')._try_handle_client_command(inst, '/rename foo')
    vim.notify = orig_notify
    return result
  end)()]])
  eq(handled, true)
end

T['dispatch']['try_handle ignores non-client commands'] = function()
  local handled = _G.child.lua_get([[(function()
    local inst = {
      last_session_id = nil,
      session = {},
      output = {},
    }
    return require('cc')._try_handle_client_command(inst, '/clear')
  end)()]])
  eq(handled, false)
end

return T
