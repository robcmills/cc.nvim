-- Tests for cc.slash: merging session slash_commands + skills with on-disk
-- ~/.claude/{commands,skills} and <cwd>/.claude/{commands,skills} entries.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Filter the result list down to a name -> source map for assertions.
--- The on-disk scans pick up the user's real ~/.claude contents during the
--- test, so we only assert against names we explicitly seed.
local function find(child, names)
  return _G.child.lua_get(string.format([[
    (function()
      local want = %s
      local list = require('cc.slash').list(_G._cmds, _G._skills)
      local out, set = {}, {}
      for _, n in ipairs(want) do set[n] = true end
      for _, c in ipairs(list) do
        if set[c.name] then
          out[c.name] = { source = c.source, description = c.description }
        end
      end
      return out
    end)()
  ]], vim.inspect(names)))
end

T['init slash_commands appear with source=init'] = function()
  _G.child.lua([[_G._cmds = { 'commit-builtin', 'plan' }; _G._skills = nil]])
  local got = find(_G.child, { 'commit-builtin', 'plan' })
  eq(got['commit-builtin'].source, 'init')
  eq(got['plan'].source, 'init')
end

T['init skills appear with source=skill'] = function()
  _G.child.lua([[
    _G._cmds = nil
    _G._skills = { 'cc-test-skill-xyz' }
  ]])
  local got = find(_G.child, { 'cc-test-skill-xyz' })
  eq(got['cc-test-skill-xyz'].source, 'skill')
end

T['skill description from SKILL.md frontmatter'] = function()
  -- Seed a project-level skill in a temp cwd, scoped to this test.
  _G.child.lua([[
    _G._tmp = vim.fn.tempname()
    vim.fn.mkdir(_G._tmp .. '/.claude/skills/cc-test-skill-xyz', 'p')
    local f = io.open(_G._tmp .. '/.claude/skills/cc-test-skill-xyz/SKILL.md', 'w')
    f:write('---\nname: cc-test-skill-xyz\ndescription: A test skill\n---\n')
    f:close()
    vim.cmd('lcd ' .. _G._tmp)
    _G._cmds = nil
    _G._skills = { 'cc-test-skill-xyz' }
  ]])
  local got = find(_G.child, { 'cc-test-skill-xyz' })
  eq(got['cc-test-skill-xyz'].source, 'skill')
  eq(got['cc-test-skill-xyz'].description, 'A test skill')
end

T['session.on_init stores skills'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    _G._s = Session.new()
    _G._s:on_init({
      session_id = 'sid',
      slash_commands = { 'plan' },
      skills = { 'address-pr-comments', 'commit' },
    })
  ]])
  eq(_G.child.lua_get('_G._s.skills'), { 'address-pr-comments', 'commit' })
  eq(_G.child.lua_get('_G._s.slash_commands'), { 'plan' })
end

return T
