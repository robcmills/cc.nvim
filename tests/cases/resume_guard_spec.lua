-- Tests for the resume guard: detecting a live claude process that already
-- holds a session id via <CLAUDE_CONFIG_DIR>/sessions/<pid>.json.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

-- Point CLAUDE_CONFIG_DIR at a temp dir, stub provider attach and
-- vim.ui.select, and define _G._test_write_session(pid, session_id).
local function setup_child(child, guard)
  child.lua([==[
    local guard = ...
    require('cc.config').setup({
      splash = false,
      statusline = { enabled = false },
      resume_guard = guard,
    })
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/sessions', 'p')
    vim.env.CLAUDE_CONFIG_DIR = dir
    _G._test_write_session = function(pid, sid)
      vim.fn.writefile({ vim.json.encode({ pid = pid, sessionId = sid, name = 'other-nvim' }) },
        dir .. '/sessions/' .. pid .. '.json')
    end
    local P = require('cc.providers.claude')
    _G._test_saved = { attach = P.attach, prerender = P.prerender_resume, select = vim.ui.select }
    _G._test_attached = {}
    _G._test_selects = {}
    P.prerender_resume = function() end
    P.attach = function(ctx)
      table.insert(_G._test_attached, ctx.resume_id)
      return { spawn = function() end, is_alive = function() return false end, close = function() end }
    end
    vim.ui.select = function(items, opts, cb)
      table.insert(_G._test_selects, { items = items, prompt = opts.prompt })
      cb(_G._test_answer)
    end
  ]==], { guard or {} })
end

local function restore_child(child)
  child.lua([==[
    local P = require('cc.providers.claude')
    P.attach, P.prerender_resume = _G._test_saved.attach, _G._test_saved.prerender
    vim.ui.select = _G._test_saved.select
    vim.env.CLAUDE_CONFIG_DIR = nil
  ]==])
end

-- A pid that is certainly dead: spawn a short process and wait for it.
local function dead_pid(child)
  return child.lua_get([[(function()
    local job = vim.fn.jobstart({ 'true' })
    local pid = vim.fn.jobpid(job)
    vim.fn.jobwait({ job }, 2000)
    return pid
  end)()]])
end

T['no live holder resumes without asking'] = function()
  setup_child(_G.child)
  _G.child.lua([[require('cc').resume('sess-free', 'claude')]])
  eq(_G.child.lua_get('_G._test_attached'), { 'sess-free' })
  eq(_G.child.lua_get('#_G._test_selects'), 0)
  restore_child(_G.child)
end

T['live holder prompts; cancel does not resume'] = function()
  setup_child(_G.child)
  _G.child.lua([[
    _G._test_write_session(vim.fn.getpid(), 'sess-live')
    _G._test_answer = 'Cancel'
    require('cc').resume('sess-live', 'claude')
  ]])
  eq(_G.child.lua_get('_G._test_attached'), {})
  local selects = _G.child.lua_get('_G._test_selects')
  eq(#selects, 1)
  eq(selects[1].items, { 'Resume anyway', 'Cancel' })
  local pid = _G.child.lua_get('vim.fn.getpid()')
  eq(selects[1].prompt:find('pid ' .. pid, 1, true) ~= nil, true)
  eq(selects[1].prompt:find('"other-nvim"', 1, true) ~= nil, true)
  restore_child(_G.child)
end

T['live holder prompts; resume anyway resumes'] = function()
  setup_child(_G.child)
  _G.child.lua([[
    _G._test_write_session(vim.fn.getpid(), 'sess-live')
    _G._test_answer = 'Resume anyway'
    require('cc').resume('sess-live', 'claude')
  ]])
  eq(_G.child.lua_get('_G._test_attached'), { 'sess-live' })
  eq(_G.child.lua_get('#_G._test_selects'), 1)
  restore_child(_G.child)
end

T['stale file with a dead pid is ignored'] = function()
  setup_child(_G.child)
  local pid = dead_pid(_G.child)
  _G.child.lua('_G._test_write_session(...)', { pid, 'sess-stale' })
  eq(_G.child.lua_get([[vim.tbl_count(require('cc.live_sessions').scan())]]), 0)
  _G.child.lua([[require('cc').resume('sess-stale', 'claude')]])
  eq(_G.child.lua_get('_G._test_attached'), { 'sess-stale' })
  eq(_G.child.lua_get('#_G._test_selects'), 0)
  restore_child(_G.child)
end

T['disabled guard skips the check'] = function()
  setup_child(_G.child, { enabled = false })
  _G.child.lua([[
    _G._test_write_session(vim.fn.getpid(), 'sess-live')
    require('cc').resume('sess-live', 'claude')
  ]])
  eq(_G.child.lua_get('_G._test_attached'), { 'sess-live' })
  eq(_G.child.lua_get('#_G._test_selects'), 0)
  restore_child(_G.child)
end

T['codex sessions are not checked'] = function()
  _G.child.lua([[
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/sessions', 'p')
    vim.env.CLAUDE_CONFIG_DIR = dir
    vim.fn.writefile({ vim.json.encode({ pid = vim.fn.getpid(), sessionId = 'thr-1' }) },
      dir .. '/sessions/' .. vim.fn.getpid() .. '.json')
    local P = require('cc.providers.codex')
    local attach, prerender, select = P.attach, P.prerender_resume, vim.ui.select
    _G._test_selected = false
    vim.ui.select = function() _G._test_selected = true end
    P.prerender_resume = function() end
    P.attach = function()
      return { spawn = function() end, is_alive = function() return false end, close = function() end }
    end
    require('cc').resume('thr-1', 'codex')
    P.attach, P.prerender_resume, vim.ui.select = attach, prerender, select
    vim.env.CLAUDE_CONFIG_DIR = nil
  ]])
  eq(_G.child.lua_get('_G._test_selected'), false)
end

T['history picker marks live entries'] = function()
  setup_child(_G.child)
  _G.child.lua([[
    _G._test_write_session(vim.fn.getpid(), 'sess-live')
    local Providers = require('cc.providers')
    local Picker = require('cc.picker')
    local list, select = Providers.list_history, Picker.select
    Providers.list_history = function(_, cb)
      cb({
        { session_id = 'sess-live', provider = 'claude', mtime = os.time(), title = 'live one' },
        { session_id = 'sess-idle', provider = 'claude', mtime = os.time(), title = 'idle one' },
      })
    end
    _G._test_lines = {}
    Picker.select = function(items, opts)
      for _, item in ipairs(items) do table.insert(_G._test_lines, opts.format_item(item)) end
    end
    require('cc').history(false)
    Providers.list_history, Picker.select = list, select
  ]])
  local lines = _G.child.lua_get('_G._test_lines')
  eq(vim.startswith(lines[1], '● '), true)
  eq(vim.startswith(lines[2], '  '), true)
  restore_child(_G.child)
end

return T
