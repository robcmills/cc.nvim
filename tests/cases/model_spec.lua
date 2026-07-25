-- Model shorthand, fuzzy resolution, and completion.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['resolve'] = MiniTest.new_set()

T['resolve']['expands provider shorthand to the canonical model'] = function()
  local got = _G.child.lua_get([[(function()
    local model, provider, status = require('cc.model').resolve('sol')
    return { model = model, provider = provider, status = status }
  end)()]])
  eq(got, {
    model = 'gpt-5.6-sol',
    provider = 'codex',
    status = 'shorthand',
  })
end

T['resolve']['accepts compact names and small typos'] = function()
  local got = _G.child.lua_get([[(function()
    local Model = require('cc.model')
    local compact, compact_provider, compact_status = Model.resolve('gpt56sol')
    local typo, typo_provider, typo_status = Model.resolve('soll')
    local claude, claude_provider, claude_status = Model.resolve('son')
    return {
      compact = { compact, compact_provider, compact_status },
      typo = { typo, typo_provider, typo_status },
      claude = { claude, claude_provider, claude_status },
    }
  end)()]])
  eq(got.compact, { 'gpt-5.6-sol', 'codex', 'shorthand' })
  eq(got.typo, { 'gpt-5.6-sol', 'codex', 'fuzzy' })
  eq(got.claude, { 'sonnet', 'claude', 'shorthand' })
end

T['resolve']['opus aliases select the versioned Opus 5 model'] = function()
  local got = _G.child.lua_get([[(function()
    local Model = require('cc.model')
    local alias, alias_provider, alias_status = Model.resolve('opus')
    local compact, compact_provider, compact_status = Model.resolve('opus5')
    require('cc.config').setup({
      providers = { claude = { model = 'opus' } },
    })
    local configured, configured_provider = Model.resolve('opus')
    return {
      alias = { alias, alias_provider, alias_status },
      compact = { compact, compact_provider, compact_status },
      configured = { configured, configured_provider },
    }
  end)()]])
  eq(got.alias, { 'claude-opus-5', 'claude', 'shorthand' })
  eq(got.compact, { 'claude-opus-5', 'claude', 'shorthand' })
  eq(got.configured, { 'claude-opus-5', 'claude' })
end

T['resolve']['ambiguous prefixes are not guessed'] = function()
  local got = _G.child.lua_get([[(function()
    local model, provider, status, suggestions = require('cc.model').resolve('gpt')
    return {
      model = model,
      provider = provider,
      status = status,
      suggestions = suggestions,
    }
  end)()]])
  eq(got.model, nil)
  eq(got.provider, nil)
  eq(got.status, 'ambiguous')
  eq(vim.tbl_contains(got.suggestions, 'gpt-5.6-sol'), true)
  eq(vim.tbl_contains(got.suggestions, 'gpt-5.6-luna'), true)
end

T['resolve']['configured generation wins for a stable shorthand'] = function()
  local got = _G.child.lua_get([[(function()
    require('cc.config').setup({
      providers = { codex = { model = 'gpt-9-sol' } },
    })
    local model, provider = require('cc.model').resolve('sol')
    return { model = model, provider = provider }
  end)()]])
  eq(got.model, 'gpt-9-sol')
  eq(got.provider, 'codex')
end

T['resolve']['unknown custom model is preserved'] = function()
  local got = _G.child.lua_get([[(function()
    local model, provider, status = require('cc.model').resolve('company-model')
    return { model = model, provider = provider, status = status }
  end)()]])
  eq(got.model, 'company-model')
  eq(got.provider, nil)
  eq(got.status, 'unknown')
end

T['complete'] = MiniTest.new_set()

T['complete']['fuzzy query returns the canonical model first'] = function()
  _G.child.lua([[require('cc.config').setup({})]])
  local got = _G.child.lua_get([[require('cc.model').complete('sol')]])
  eq(got[1], 'gpt-5.6-sol')
end

T['complete']['shows the versioned Opus 5 model'] = function()
  _G.child.lua([[require('cc.config').setup({})]])
  local all = _G.child.lua_get([[require('cc.model').complete('')]])
  local compact = _G.child.lua_get([[require('cc.model').complete('opus5')]])
  eq(vim.tbl_contains(all, 'claude-opus-5'), true)
  eq(vim.tbl_contains(all, 'opus'), false)
  eq(compact[1], 'claude-opus-5')
end

T['complete']['provider filter excludes the other provider'] = function()
  _G.child.lua([[require('cc.config').setup({})]])
  local got = _G.child.lua_get([[require('cc.model').complete('', 'claude')]])
  eq(vim.tbl_contains(got, 'sonnet'), true)
  eq(vim.tbl_contains(got, 'gpt-5.6-sol'), false)
end

return T
