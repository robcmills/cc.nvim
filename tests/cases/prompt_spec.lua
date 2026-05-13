-- Tests for the prompt buffer's invariants (separate from placeholder_spec,
-- which only covers the inline placeholder text).
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

local function prompt_buflisted(child)
  return child.lua_get([[
    (function()
      local inst = require('cc')._get_instance()
      if not inst or not inst.prompt then return nil end
      return vim.bo[inst.prompt.bufnr].buflisted
    end)()
  ]])
end

T['buflisted'] = MiniTest.new_set()

T['buflisted']['prompt buffer is unlisted after open'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  eq(prompt_buflisted(_G.child), false)
end

-- `:edit <name>` on an existing buffer flips its `buflisted` to true. Plugins
-- like telescope effectively call `:edit` (or directly set buflisted=true)
-- when the user picks a buffer. Without a guard, the prompt buffer leaks
-- into buffer-list sidebars after such navigation.
T['buflisted']['stays unlisted after :edit on the prompt buffer name'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  eq(prompt_buflisted(_G.child), false)
  _G.child.lua([[vim.cmd('edit cc-nvim-prompt')]])
  eq(prompt_buflisted(_G.child), false)
end

T['buflisted']['stays unlisted when buflisted is set externally'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  -- Simulate a plugin (e.g. telescope/actions/set.lua) flipping buflisted.
  _G.child.lua([[
    local inst = require('cc')._get_instance()
    vim.bo[inst.prompt.bufnr].buflisted = true
    -- Trigger BufEnter so the guard runs (the `:edit`-equivalent path also
    -- emits BufEnter; see the `:edit` test above for the natural trigger).
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = inst.prompt.bufnr })
  ]])
  eq(prompt_buflisted(_G.child), false)
end

return T
