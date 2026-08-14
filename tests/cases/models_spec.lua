-- cc.models: catalog normalization, cache reads, and :CcModelsUpdate
-- fetches against the fake provider CLIs.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['normalize'] = MiniTest.new_set()

T['normalize']['claude catalog skips the default pseudo-entry'] = function()
  local got = _G.child.lua_get([[require('cc.models')._from_claude({
    { value = 'default', displayName = 'Default (recommended)',
      supportsEffort = true, supportedEffortLevels = { 'low', 'high' } },
    { value = 'opus[1m]', displayName = 'Opus (1M context)',
      supportsEffort = true, supportedEffortLevels = { 'low', 'high' } },
    { value = 'haiku', displayName = 'Haiku' },
  })]])
  eq(#got, 2)
  eq(got[1], { name = 'opus[1m]', display = 'Opus (1M context)', efforts = { 'low', 'high' } })
  eq(got[2], { name = 'haiku', display = 'Haiku' })
end

T['normalize']['codex catalog skips hidden models'] = function()
  local got = _G.child.lua_get([[require('cc.models')._from_codex({
    { id = 'gpt-a', displayName = 'A', hidden = false, isDefault = true,
      supportedReasoningEfforts = {
        { reasoningEffort = 'low', description = 'low' },
        { reasoningEffort = 'max', description = 'max' },
      } },
    { id = 'gpt-b', displayName = 'B', hidden = true, isDefault = false,
      supportedReasoningEfforts = {} },
  })]])
  eq(#got, 1)
  eq(got[1], { name = 'gpt-a', display = 'A', efforts = { 'low', 'max' }, default = true })
end

T['cache'] = MiniTest.new_set()

T['cache']['cached() reads entries from models_path'] = function()
  _G.child.lua(('require("cc.config").setup({ models_path = %q })')
    :format(helpers.models_fixture))
  local claude = _G.child.lua_get([[require('cc.models').cached('claude')]])
  local codex = _G.child.lua_get([[require('cc.models').cached('codex')]])
  eq(claude[1].name, 'opus[1m]')
  eq(#claude, 4)
  eq(codex[1].name, 'gpt-5.6-sol')
  eq(codex[1].default, true)
  eq(#codex, 6)
end

T['cache']['missing cache yields no candidates'] = function()
  _G.child.lua([[require('cc.config').setup({
    models_path = '/nonexistent/cc-models-test.json',
  })]])
  eq(_G.child.lua_get([[require('cc.models').cached('claude')]]), {})
  eq(_G.child.lua_get([[require('cc.model').complete('')]]), {})
end

--- Run cc.models.update in the child against a fake CLI and wait for it.
---@param provider 'claude'|'codex'
---@param fake_cmd string
---@return table results, table errors (as decoded from the child)
local function run_update(provider, fake_cmd)
  local cache_path = _G.child.lua_get('vim.fn.tempname()') .. '.json'
  _G.child.lua(([==[
    require('cc.config').setup({
      models_path = %q,
      providers = { %s = { cmd = %q } },
    })
    _G._test_update_done = nil
    require('cc.models').update({ providers = { %q } }, function(results, errors)
      _G._test_update_done = { results = results, errors = errors }
    end)
  ]==]):format(cache_path, provider, fake_cmd, provider))
  local ok = vim.wait(15000, function()
    return _G.child.lua_get('_G._test_update_done ~= nil') == true
  end, 100)
  eq(ok, true)
  local done = _G.child.lua_get('_G._test_update_done')
  return done.results or {}, done.errors or {}
end

T['update'] = MiniTest.new_set()

T['update']['fetches claude models via an ephemeral CLI'] = function()
  local results, errors = run_update('claude', helpers.this_dir .. '/fixtures/fake_claude_models.sh')
  eq(errors, {})
  eq(#results.claude, 2)
  eq(results.claude[1].name, 'claude-test-1')
  eq(results.claude[2].name, 'test-two')
  -- Cache is written and immediately drives resolution + completion.
  local cached = _G.child.lua_get([[require('cc.models').cached('claude')]])
  eq(cached[1].name, 'claude-test-1')
  local resolved = _G.child.lua_get([[{ require('cc.model').resolve('test-two') }]])
  eq(resolved[1], 'test-two')
  eq(resolved[2], 'claude')
end

T['update']['fetches codex models via an ephemeral app-server'] = function()
  local results, errors = run_update('codex', helpers.this_dir .. '/fixtures/fake_codex.sh')
  eq(errors, {})
  eq(#results.codex, 1) -- gpt-hidden filtered out
  eq(results.codex[1].name, 'gpt-test')
  eq(results.codex[1].efforts, { 'low', 'high' })
  local complete = _G.child.lua_get([[require('cc.model').complete('', 'codex')]])
  eq(complete, { 'gpt-test' })
end

T['update']['reports a failure for an unreachable CLI'] = function()
  local results, errors = run_update('codex', '/nonexistent/cc-fake-codex')
  eq(results, {})
  eq(type(errors.codex), 'string')
end

return T
