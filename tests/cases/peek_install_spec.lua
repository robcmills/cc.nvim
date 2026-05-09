-- Tests for :CcPeekInstall / :CcPeekUninstall — verifies idempotent edits
-- to settings.json against a temp HOME so we don't touch the user's real
-- ~/.claude/settings.json.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

--- Redirect HOME (and re-require cc.peek so its module-level path constants
--- pick up the new HOME). Returns { home, settings, script }.
local function setup_temp_home(child)
  return child.lua_get([[(function()
    local home = vim.fn.tempname()
    vim.fn.mkdir(home, 'p')
    vim.env.HOME = home
    -- Force the cc.peek module to re-evaluate its `vim.fn.expand('~')` paths.
    package.loaded['cc.peek'] = nil
    return {
      home = home,
      settings = home .. '/.claude/settings.json',
      script = home .. '/.claude/hooks/cc-peek-wrap.sh',
    }
  end)()]])
end

local function read_json(child, path)
  return child.lua_get(string.format([[(function()
    local raw = table.concat(vim.fn.readfile(%q), '\n')
    return vim.json.decode(raw, { luanil = { object = true, array = true } })
  end)()]], path))
end

T['install'] = MiniTest.new_set()

T['install']['creates hook script and registers settings entry'] = function()
  local p = setup_temp_home(_G.child)
  _G.child.lua([[require('cc.peek').install()]])

  -- Script copied and executable.
  eq(_G.child.lua_get(string.format([[vim.fn.filereadable(%q)]], p.script)), 1)
  eq(_G.child.lua_get(string.format([[vim.fn.executable(%q)]], p.script)), 1)

  -- Settings.json registers a Bash matcher pointing at the script.
  local settings = read_json(_G.child, p.settings)
  eq(type(settings.hooks), 'table')
  eq(type(settings.hooks.PreToolUse), 'table')
  local found = false
  for _, group in ipairs(settings.hooks.PreToolUse) do
    if group.matcher == 'Bash' then
      for _, hook in ipairs(group.hooks or {}) do
        if hook.command and hook.command:find('cc%-peek%-wrap%.sh') then
          found = true
        end
      end
    end
  end
  eq(found, true)
end

T['install']['is idempotent (running twice does not duplicate)'] = function()
  local p = setup_temp_home(_G.child)
  _G.child.lua([[require('cc.peek').install()]])
  _G.child.lua([[require('cc.peek').install()]])

  local settings = read_json(_G.child, p.settings)
  local count = 0
  for _, group in ipairs(settings.hooks.PreToolUse or {}) do
    if group.matcher == 'Bash' then
      for _, hook in ipairs(group.hooks or {}) do
        if hook.command and hook.command:find('cc%-peek%-wrap%.sh') then
          count = count + 1
        end
      end
    end
  end
  eq(count, 1)
end

T['install']['preserves unrelated keys in settings.json'] = function()
  local p = setup_temp_home(_G.child)
  _G.child.lua(string.format([[
    vim.fn.mkdir(vim.fn.fnamemodify(%q, ':h'), 'p')
    vim.fn.writefile({ vim.json.encode({
      theme = 'dark',
      hooks = { Stop = { { hooks = { { type = 'command', command = 'echo done' } } } } },
    }) }, %q)
  ]], p.settings, p.settings))

  _G.child.lua([[require('cc.peek').install()]])

  local settings = read_json(_G.child, p.settings)
  eq(settings.theme, 'dark')
  eq(type(settings.hooks.Stop), 'table')
  eq(type(settings.hooks.PreToolUse), 'table')
end

T['uninstall'] = MiniTest.new_set()

T['uninstall']['removes the matcher entry'] = function()
  local p = setup_temp_home(_G.child)
  _G.child.lua([[require('cc.peek').install()]])
  _G.child.lua([[require('cc.peek').uninstall()]])

  local settings = read_json(_G.child, p.settings)
  -- After uninstall, no PreToolUse entry referencing the hook should remain.
  local found = false
  for _, group in ipairs((settings.hooks or {}).PreToolUse or {}) do
    for _, hook in ipairs(group.hooks or {}) do
      if hook.command and hook.command:find('cc%-peek%-wrap%.sh') then
        found = true
      end
    end
  end
  eq(found, false)
end

T['uninstall']['leaves unrelated PreToolUse entries intact'] = function()
  local p = setup_temp_home(_G.child)
  _G.child.lua(string.format([[
    vim.fn.mkdir(vim.fn.fnamemodify(%q, ':h'), 'p')
    vim.fn.writefile({ vim.json.encode({
      hooks = {
        PreToolUse = {
          { matcher = 'Edit', hooks = { { type = 'command', command = 'echo edit-hook' } } },
        },
      },
    }) }, %q)
  ]], p.settings, p.settings))

  _G.child.lua([[require('cc.peek').install()]])
  _G.child.lua([[require('cc.peek').uninstall()]])

  local settings = read_json(_G.child, p.settings)
  -- The Edit matcher should still be there.
  local edit_kept = false
  for _, group in ipairs((settings.hooks or {}).PreToolUse or {}) do
    if group.matcher == 'Edit' then edit_kept = true end
  end
  eq(edit_kept, true)
end

return T
