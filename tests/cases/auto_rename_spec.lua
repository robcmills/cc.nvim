-- Tests for cc.auto_rename: prompt template rendering, default sanitizer,
-- and the should_run guard. The actual subprocess spawn is not exercised
-- here; that path would require a real `claude` binary.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

-- ---------------------------------------------------------------------------
-- render_prompt
-- ---------------------------------------------------------------------------
T['render_prompt'] = MiniTest.new_set()

T['render_prompt']['substitutes ${prompt}'] = function()
  local out = _G.child.lua_get(
    [[require('cc.auto_rename').render_prompt('name this: ${prompt}', 'hello world')]])
  eq(out, 'name this: hello world')
end

T['render_prompt']['handles multiple occurrences'] = function()
  local out = _G.child.lua_get(
    [[require('cc.auto_rename').render_prompt('${prompt}/${prompt}', 'x')]])
  eq(out, 'x/x')
end

T['render_prompt']['does not interpret % escapes in prompt body'] = function()
  -- gsub's replacement-string syntax treats %1, %0, etc. specially. Using a
  -- function replacement avoids that. Verify by passing a prompt containing
  -- literal `%1` characters.
  local out = _G.child.lua_get(
    [[require('cc.auto_rename').render_prompt('prefix: ${prompt}', '50%1 done')]])
  eq(out, 'prefix: 50%1 done')
end

T['render_prompt']['nil prompt -> empty substitution'] = function()
  local out = _G.child.lua_get(
    [[require('cc.auto_rename').render_prompt('->${prompt}<-', nil)]])
  eq(out, '-><-')
end

-- ---------------------------------------------------------------------------
-- default_validate
-- ---------------------------------------------------------------------------
T['default_validate'] = MiniTest.new_set()

local function validate(child, raw)
  return child.lua_get(string.format(
    [[require('cc.auto_rename').default_validate(%q)]], raw))
end

T['default_validate']['trims whitespace'] = function()
  eq(validate(_G.child, '  fix-login-bug  '), 'fix-login-bug')
end

T['default_validate']['drops content after first newline'] = function()
  eq(validate(_G.child, 'fix-login-bug\nHere is why: ...'), 'fix-login-bug')
end

T['default_validate']['strips surrounding double quotes'] = function()
  eq(validate(_G.child, '"fix-login-bug"'), 'fix-login-bug')
end

T['default_validate']['strips surrounding single quotes'] = function()
  eq(validate(_G.child, "'fix-login-bug'"), 'fix-login-bug')
end

T['default_validate']['caps length at 64'] = function()
  local long = string.rep('a', 100)
  local out = validate(_G.child, long)
  eq(#out, 64)
end

T['default_validate']['empty input -> nil'] = function()
  local out = _G.child.lua_get([[require('cc.auto_rename').default_validate('   ')]])
  eq(out, vim.NIL)
end

T['default_validate']['non-string input -> nil'] = function()
  local out = _G.child.lua_get([[require('cc.auto_rename').default_validate(nil)]])
  eq(out, vim.NIL)
end

-- ---------------------------------------------------------------------------
-- should_run
-- ---------------------------------------------------------------------------
T['should_run'] = MiniTest.new_set()

local function should(child, inst_lua)
  return child.lua_get(string.format(
    [[(function()
      local inst = %s
      return require('cc.auto_rename').should_run(inst)
    end)()]], inst_lua))
end

T['should_run']['fires on fresh unnamed instance with no turns'] = function()
  local r = should(_G.child, [[{ session = { turns = {} } }]])
  eq(r, true)
end

T['should_run']['skips when disabled in config'] = function()
  _G.child.lua([[require('cc.config').setup({ auto_rename = { enabled = false } })]])
  local r = should(_G.child, [[{ session = { turns = {} } }]])
  eq(r, false)
  -- Reset for subsequent tests.
  _G.child.lua([[require('cc.config').setup({})]])
end

T['should_run']['skips on fixture instances'] = function()
  local r = should(_G.child, [[{ is_fixture = true, session = { turns = {} } }]])
  eq(r, false)
end

T['should_run']['skips when session_name is set'] = function()
  local r = should(_G.child,
    [[{ session_name = 'already-named', session = { turns = {} } }]])
  eq(r, false)
end

T['should_run']['skips when pending_session_name is set'] = function()
  local r = should(_G.child,
    [[{ pending_session_name = 'queued', session = { turns = {} } }]])
  eq(r, false)
end

T['should_run']['skips after first turn'] = function()
  local r = should(_G.child,
    [[{ session = { turns = { { role = 'user', text = 'hi' } } } }]])
  eq(r, false)
end

T['should_run']['skips when an auto-rename is already in flight'] = function()
  local r = should(_G.child,
    [[{ auto_rename_in_flight = true, session = { turns = {} } }]])
  eq(r, false)
end

-- ---------------------------------------------------------------------------
-- Custom validate override (config-level)
-- ---------------------------------------------------------------------------
T['custom_validate'] = MiniTest.new_set()

T['custom_validate']['user validate function replaces the default'] = function()
  local out = _G.child.lua_get([[(function()
    require('cc.config').setup({
      auto_rename = {
        enabled = true,
        prompt = 'x',
        validate = function(raw) return raw:upper() end,
      },
    })
    local cfg = require('cc.config').options.auto_rename
    local AutoRename = require('cc.auto_rename')
    local validate = cfg.validate or AutoRename.default_validate
    local name = validate('hello-world')
    require('cc.config').setup({})
    return name
  end)()]])
  eq(out, 'HELLO-WORLD')
end

-- ---------------------------------------------------------------------------
-- provider worker
-- ---------------------------------------------------------------------------
T['provider_worker'] = MiniTest.new_set()

T['provider_worker']['waits for stdout EOF before applying title'] = function()
  local out = _G.child.lua_get([[(function()
    require('cc.config').setup({
      auto_rename = { enabled = true, prompt = '${prompt}', placeholder = false },
    })
    local inst
    local provider = {
      auto_rename_spec = function()
        return {
          cmd = 'sh',
          args = { '-c', 'printf generated-from-stdout' },
        }
      end,
      rename = function(_, name, cb)
        inst.applied_name = name
        if cb then cb(true) end
        return true
      end,
    }
    inst = { provider = provider, session = { turns = {} } }
    require('cc.auto_rename').start(inst, 'ignored')
    vim.wait(2000, function() return inst.auto_rename_in_flight == false end, 10)
    return {
      name = inst.applied_name,
      in_flight = inst.auto_rename_in_flight,
    }
  end)()]])
  eq(out.name, 'generated-from-stdout')
  eq(out.in_flight, false)
end

T['provider_worker']['ignores Bash login output before the provider starts'] = function()
  local out = _G.child.lua_get([==[(function()
    require('cc.config').setup({
      auto_rename = { enabled = true, prompt = '${prompt}', placeholder = false },
    })
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local fake_bash = tmp .. '/bash'
    vim.fn.writefile({
      '#!/bin/bash',
      'printf "Using Node v24.13.0\\n"',
      'if [[ $1 == -lc ]]; then shift; set -- -c "$@"; fi',
      'exec /bin/bash "$@"',
    }, fake_bash)
    vim.fn.setfperm(fake_bash, 'rwx------')

    local old_shell = vim.env.SHELL
    vim.env.SHELL = fake_bash
    local inst
    local provider = {
      auto_rename_spec = function()
        return {
          cmd = 'printf',
          args = { 'generated-title' },
        }
      end,
      rename = function(_, name, cb)
        inst.applied_name = name
        if cb then cb(true) end
        return true
      end,
    }
    inst = { provider = provider, session = { turns = {} } }
    require('cc.auto_rename').start(inst, 'ignored')
    vim.wait(2000, function() return inst.auto_rename_in_flight == false end, 10)
    vim.env.SHELL = old_shell
    vim.fn.delete(tmp, 'rf')
    return inst.applied_name
  end)()]==])
  eq(out, 'generated-title')
end

T['provider_worker']['reads and cleans provider output file'] = function()
  local out = _G.child.lua_get([[(function()
    require('cc.config').setup({
      auto_rename = { enabled = true, prompt = '${prompt}', placeholder = false },
    })
    local inst
    local output_path
    local provider = {
      auto_rename_spec = function()
        output_path = vim.fn.tempname()
        return {
          cmd = 'sh',
          args = { '-c', 'printf generated-from-file > "$1"', 'cc-auto-rename',
            output_path },
          output_path = output_path,
          cleanup = function() pcall((vim.uv or vim.loop).fs_unlink, output_path) end,
        }
      end,
      rename = function(_, name, cb)
        inst.applied_name = name
        if cb then cb(true) end
        return true
      end,
    }
    inst = { provider = provider, session = { turns = {} } }
    require('cc.auto_rename').start(inst, 'ignored')
    vim.wait(2000, function() return inst.auto_rename_in_flight == false end, 10)
    return {
      name = inst.applied_name,
      output_removed = (vim.uv or vim.loop).fs_stat(output_path) == nil,
    }
  end)()]])
  eq(out.name, 'generated-from-file')
  eq(out.output_removed, true)
end

return T
