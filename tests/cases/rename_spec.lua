-- Tests for /rename: client-side interception, custom-title persistence,
-- and read-back through history metadata.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
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
    local output_name_calls = {}
    local inst = {
      last_session_id = session_id,
      session_name = nil,
      session = {},
      prompt = {},
      output = {
        set_buf_name = function(self, name) table.insert(output_name_calls, name) end,
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
      output_name = output_name_calls[1],
    }
  end)()]])
  eq(result.session_name, 'my-new-name')
  eq(result.last_type, 'custom-title')
  eq(result.last_title, 'my-new-name')
  eq(result.notice, 'cc.nvim: session renamed to "my-new-name"')
  eq(result.output_name, 'cc-my-new-name')
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

-- ---------------------------------------------------------------------------
-- Pre-begin rename (queued + flushed by router events)
-- ---------------------------------------------------------------------------
T['pre_begin'] = MiniTest.new_set()

T['pre_begin']['queues rename when no session id and applies buffer name'] = function()
  local result = _G.child.lua_get([[(function()
    local notices = {}
    local orig_notify = vim.notify
    vim.notify = function(text, _) table.insert(notices, text) end
    local output_name_calls = {}
    local inst = {
      last_session_id = nil,
      session_name = nil,
      pending_session_name = nil,
      session = {},
      prompt = {},
      output = {
        set_buf_name = function(self, name) table.insert(output_name_calls, name) end,
      },
    }
    require('cc')._handle_rename(inst, 'fresh-name')
    vim.notify = orig_notify
    return {
      pending = inst.pending_session_name,
      session_name = inst.session_name,
      output_name = output_name_calls[1],
      notice = notices[1],
    }
  end)()]])
  eq(result.pending, 'fresh-name')
  eq(result.session_name, nil)
  eq(result.output_name, 'cc-fresh-name')
  local ok = result.notice and result.notice:match('queued') ~= nil
  eq(ok, true)
end

T['pre_begin']['queues rename when session id known but transcript missing'] = function()
  local result = _G.child.lua_get([[(function()
    local history = require('cc.history')
    local orig = history.session_path
    history.session_path = function(_) return nil end
    local notices = {}
    local orig_notify = vim.notify
    vim.notify = function(text, _) table.insert(notices, text) end
    local inst = {
      last_session_id = 'abc-123',
      session_name = nil,
      pending_session_name = nil,
      session = {},
      prompt = {},
      output = { set_buf_name = function(_, _) end },
    }
    require('cc')._handle_rename(inst, 'queued')
    history.session_path = orig
    vim.notify = orig_notify
    return { pending = inst.pending_session_name, notice = notices[1] }
  end)()]])
  eq(result.pending, 'queued')
  local ok = result.notice and result.notice:match('queued') ~= nil
  eq(ok, true)
end

T['pre_begin']['empty args reports pending name when one is queued'] = function()
  local notice = _G.child.lua_get([[(function()
    local notices = {}
    local orig_notify = vim.notify
    vim.notify = function(text, _) table.insert(notices, text) end
    local inst = {
      last_session_id = nil,
      session_name = nil,
      pending_session_name = 'queued-name',
      session = {},
      output = {},
    }
    require('cc')._handle_rename(inst, '')
    vim.notify = orig_notify
    return notices[1]
  end)()]])
  local ok = notice and notice:match('pending') ~= nil
  eq(ok, true)
end

T['pre_begin']['flush persists queued name once transcript exists'] = function()
  local result = _G.child.lua_get([[(function()
    local tmp_project = vim.fn.tempname()
    vim.fn.mkdir(tmp_project, 'p')
    local session_id = 'aaaa-bbbb-cccc-dddd'
    local path = tmp_project .. '/' .. session_id .. '.jsonl'
    local f = io.open(path, 'w')
    f:write(vim.json.encode({ type='user', sessionId=session_id,
      cwd=vim.fn.getcwd(), message={role='user',content='seed'} }) .. '\n')
    f:close()

    local history = require('cc.history')
    local orig = history.session_path
    history.session_path = function(sid) if sid == session_id then return path end end

    local output_name_calls = {}
    local inst = {
      last_session_id = session_id,
      session_name = nil,
      pending_session_name = 'queued-title',
      session = {},
      prompt = {},
      output = {
        set_buf_name = function(self, name) table.insert(output_name_calls, name) end,
      },
    }
    require('cc')._flush_pending_rename(inst)
    history.session_path = orig

    local lines = vim.fn.readfile(path)
    local last = vim.json.decode(lines[#lines])
    return {
      session_name = inst.session_name,
      pending = inst.pending_session_name,
      last_type = last.type,
      last_title = last.customTitle,
      output_name = output_name_calls[1],
    }
  end)()]])
  eq(result.session_name, 'queued-title')
  eq(result.pending, nil)
  eq(result.last_type, 'custom-title')
  eq(result.last_title, 'queued-title')
  eq(result.output_name, 'cc-queued-title')
end

T['pre_begin']['flush is no-op when nothing pending'] = function()
  local result = _G.child.lua_get([[(function()
    local inst = {
      last_session_id = 'abc',
      session_name = nil,
      pending_session_name = nil,
      session = {},
      output = {},
    }
    require('cc')._flush_pending_rename(inst)
    return { session_name = inst.session_name }
  end)()]])
  eq(result.session_name, nil)
end

-- ---------------------------------------------------------------------------
-- find_unique_session_name (helper, direct)
-- ---------------------------------------------------------------------------
T['find_unique_session_name'] = MiniTest.new_set()

T['find_unique_session_name']['returns desired when no collision'] = function()
  local got = _G.child.lua_get([[(function()
    local history = require('cc.history')
    history.list_for_cwd = function() return {} end
    return history.find_unique_session_name('foo')
  end)()]])
  eq(got, 'foo')
end

T['find_unique_session_name']['appends -2 on collision'] = function()
  local got = _G.child.lua_get([[(function()
    local history = require('cc.history')
    history.list_for_cwd = function()
      return { { session_id = 'other', custom_title = 'foo' } }
    end
    return history.find_unique_session_name('foo')
  end)()]])
  eq(got, 'foo-2')
end

T['find_unique_session_name']['walks past -2 to -3'] = function()
  local got = _G.child.lua_get([[(function()
    local history = require('cc.history')
    history.list_for_cwd = function()
      return {
        { session_id = 's1', custom_title = 'foo' },
        { session_id = 's2', custom_title = 'foo-2' },
      }
    end
    return history.find_unique_session_name('foo')
  end)()]])
  eq(got, 'foo-3')
end

T['find_unique_session_name']['excludes given session_id from the taken set'] = function()
  local got = _G.child.lua_get([[(function()
    local history = require('cc.history')
    history.list_for_cwd = function()
      return { { session_id = 'self', custom_title = 'foo' } }
    end
    return history.find_unique_session_name('foo', nil, 'self')
  end)()]])
  eq(got, 'foo')
end

T['find_unique_session_name']['treats ai_title as taken'] = function()
  local got = _G.child.lua_get([[(function()
    local history = require('cc.history')
    history.list_for_cwd = function()
      return { { session_id = 'other', ai_title = 'foo' } }
    end
    return history.find_unique_session_name('foo')
  end)()]])
  eq(got, 'foo-2')
end

T['find_unique_session_name']['merges extra_taken'] = function()
  local got = _G.child.lua_get([[(function()
    local history = require('cc.history')
    history.list_for_cwd = function() return {} end
    return history.find_unique_session_name('foo', nil, nil, { 'foo' })
  end)()]])
  eq(got, 'foo-2')
end

-- ---------------------------------------------------------------------------
-- dedupe wired into _handle_rename and _flush_pending_rename
-- ---------------------------------------------------------------------------
T['dedupe'] = MiniTest.new_set()

T['dedupe']['_handle_rename suffixes when title already on disk'] = function()
  local result = _G.child.lua_get([[(function()
    local tmp_project = vim.fn.tempname()
    vim.fn.mkdir(tmp_project, 'p')
    local session_id = 'self-aaaa-bbbb-cccc'
    local path = tmp_project .. '/' .. session_id .. '.jsonl'
    local f = io.open(path, 'w')
    f:write(vim.json.encode({ type='user', sessionId=session_id,
      cwd=vim.fn.getcwd(), message={role='user',content='seed'} }) .. '\n')
    f:close()

    local history = require('cc.history')
    history.session_path = function(sid) if sid == session_id then return path end end
    history.list_for_cwd = function()
      return { { session_id = 'sibling', custom_title = 'foo' } }
    end

    local orig_notify = vim.notify
    vim.notify = function() end
    local output_name_calls = {}
    local inst = {
      last_session_id = session_id,
      session_name = nil,
      session = {},
      prompt = {},
      output = {
        set_buf_name = function(self, name) table.insert(output_name_calls, name) end,
      },
    }
    require('cc')._handle_rename(inst, 'foo')
    vim.notify = orig_notify

    local lines = vim.fn.readfile(path)
    local last = vim.json.decode(lines[#lines])
    return {
      session_name = inst.session_name,
      last_title = last.customTitle,
      output_name = output_name_calls[1],
    }
  end)()]])
  eq(result.session_name, 'foo-2')
  eq(result.last_title, 'foo-2')
  eq(result.output_name, 'cc-foo-2')
end

T['dedupe']['_handle_rename leaves a sessions own title intact'] = function()
  local result = _G.child.lua_get([[(function()
    local tmp_project = vim.fn.tempname()
    vim.fn.mkdir(tmp_project, 'p')
    local session_id = 'self-1111-2222-3333'
    local path = tmp_project .. '/' .. session_id .. '.jsonl'
    local f = io.open(path, 'w')
    f:write(vim.json.encode({ type='user', sessionId=session_id,
      cwd=vim.fn.getcwd(), message={role='user',content='seed'} }) .. '\n')
    f:close()

    local history = require('cc.history')
    history.session_path = function(sid) if sid == session_id then return path end end
    history.list_for_cwd = function()
      return { { session_id = session_id, custom_title = 'foo' } }
    end

    local orig_notify = vim.notify
    vim.notify = function() end
    local inst = {
      last_session_id = session_id,
      session_name = 'foo',
      session = {},
      prompt = {},
      output = { set_buf_name = function() end },
    }
    require('cc')._handle_rename(inst, 'foo')
    vim.notify = orig_notify
    return { session_name = inst.session_name }
  end)()]])
  eq(result.session_name, 'foo')
end

T['dedupe']['pre-begin queue uses deduped title'] = function()
  local result = _G.child.lua_get([[(function()
    local history = require('cc.history')
    history.session_path = function(_) return nil end
    history.list_for_cwd = function()
      return { { session_id = 'sibling', custom_title = 'foo' } }
    end
    local orig_notify = vim.notify
    vim.notify = function() end
    local output_name_calls = {}
    local inst = {
      last_session_id = nil,
      session_name = nil,
      pending_session_name = nil,
      session = {},
      prompt = {},
      output = {
        set_buf_name = function(self, name) table.insert(output_name_calls, name) end,
      },
    }
    require('cc')._handle_rename(inst, 'foo')
    vim.notify = orig_notify
    return {
      pending = inst.pending_session_name,
      output_name = output_name_calls[1],
    }
  end)()]])
  eq(result.pending, 'foo-2')
  eq(result.output_name, 'cc-foo-2')
end

T['dedupe']['_flush_pending_rename re-dedupes against latest on-disk state'] = function()
  local result = _G.child.lua_get([[(function()
    local tmp_project = vim.fn.tempname()
    vim.fn.mkdir(tmp_project, 'p')
    local session_id = 'self-9999-8888-7777'
    local path = tmp_project .. '/' .. session_id .. '.jsonl'
    local f = io.open(path, 'w')
    f:write(vim.json.encode({ type='user', sessionId=session_id,
      cwd=vim.fn.getcwd(), message={role='user',content='seed'} }) .. '\n')
    f:close()

    local history = require('cc.history')
    history.session_path = function(sid) if sid == session_id then return path end end
    -- Between queue time and flush time, a sibling session claimed 'foo'.
    history.list_for_cwd = function()
      return { { session_id = 'sibling', custom_title = 'foo' } }
    end

    local output_name_calls = {}
    local inst = {
      last_session_id = session_id,
      session_name = nil,
      pending_session_name = 'foo',
      session = {},
      prompt = {},
      output = {
        set_buf_name = function(self, name) table.insert(output_name_calls, name) end,
      },
    }
    require('cc')._flush_pending_rename(inst)

    local lines = vim.fn.readfile(path)
    local last = vim.json.decode(lines[#lines])
    return {
      session_name = inst.session_name,
      last_title = last.customTitle,
      output_name = output_name_calls[1],
    }
  end)()]])
  eq(result.session_name, 'foo-2')
  eq(result.last_title, 'foo-2')
  eq(result.output_name, 'cc-foo-2')
end

T['pre_begin']['flush is no-op when transcript still missing'] = function()
  local result = _G.child.lua_get([[(function()
    local history = require('cc.history')
    local orig = history.session_path
    history.session_path = function(_) return nil end
    local inst = {
      last_session_id = 'abc',
      session_name = nil,
      pending_session_name = 'still-queued',
      session = {},
      output = {},
    }
    require('cc')._flush_pending_rename(inst)
    history.session_path = orig
    return {
      session_name = inst.session_name,
      pending = inst.pending_session_name,
    }
  end)()]])
  eq(result.session_name, nil)
  eq(result.pending, 'still-queued')
end

return T
