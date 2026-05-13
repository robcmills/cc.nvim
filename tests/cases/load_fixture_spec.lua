-- Tests for cc.load_fixture / :CcLoadFixture: fixture resolution, rendering,
-- placeholder override, and submit interception.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

local function output_lines(child)
  return child.lua_get([[
    (function()
      local inst = require('cc')._get_instance()
      if not inst or not inst.output then return {} end
      return vim.api.nvim_buf_get_lines(inst.output.bufnr, 0, -1, false)
    end)()
  ]])
end

T['load_fixture'] = MiniTest.new_set()

T['load_fixture']['renders a JSONL fixture'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  local text = table.concat(output_lines(_G.child), '\n')
  -- simple_text fixture contains "apple banana cherry" in a user turn.
  if not text:find('apple banana cherry', 1, true) then
    error('expected "apple banana cherry" in output buffer; got:\n' .. text)
  end
end

T['load_fixture']['renders an NDJSON fixture'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text.ndjson')]])
  local lines = output_lines(_G.child)
  -- Should produce a non-trivial render (at minimum a turn header + content).
  eq(#lines > 1, true)
end

T['load_fixture']['marks the instance as is_fixture'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  eq(_G.child.lua_get([[require('cc')._get_instance().is_fixture]]), true)
end

T['load_fixture']['does not spawn a process'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  eq(_G.child.lua_get([[require('cc')._get_instance().process]]), vim.NIL)
end

T['load_fixture']['sets session_name to the fixture basename'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  eq(_G.child.lua_get([[require('cc')._get_instance().session_name]]), 'simple_text')
end

T['load_fixture']['renames the output buffer to cc-<fixture>'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  local name = _G.child.lua_get([[
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(require('cc')._get_instance().output.bufnr), ':t')
  ]])
  eq(name, 'cc-simple_text')
end

T['load_fixture']['appends a fixture notice'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  local text = table.concat(output_lines(_G.child), '\n')
  if not text:find('fixture: simple_text', 1, true) then
    error('expected fixture notice; got:\n' .. text)
  end
end

T['load_fixture']['warns on missing fixture'] = function()
  _G.child.lua([[
    _G._notify_msgs = {}
    vim.notify = function(msg) table.insert(_G._notify_msgs, msg) end
    require('cc').load_fixture('does_not_exist_xyz')
  ]])
  local msgs = _G.child.lua_get('_G._notify_msgs')
  local found = false
  for _, m in ipairs(msgs) do
    if m:find('fixture not found', 1, true) then found = true; break end
  end
  eq(found, true)
end

T['placeholder'] = MiniTest.new_set()

T['placeholder']['fixture override is rendered'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  local marks = _G.child.lua_get([[
    (function()
      local inst = require('cc')._get_instance()
      local ns = vim.api.nvim_get_namespaces()['cc.placeholder']
      if not ns then return {} end
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(inst.prompt.bufnr, ns, 0, -1, { details = true })) do
        if m[4] and m[4].virt_text then
          for _, vt in ipairs(m[4].virt_text) do table.insert(out, vt[1]) end
        end
      end
      return out
    end)()
  ]])
  local joined = table.concat(marks, ' ')
  if not joined:find('Viewing static fixture', 1, true) then
    error('expected fixture placeholder text; got: ' .. joined)
  end
end

T['submit'] = MiniTest.new_set()

T['submit']['is intercepted in fixture mode'] = function()
  _G.child.lua([[
    require('cc').load_fixture('simple_text')
    _G._notify_msgs = {}
    vim.notify = function(msg) table.insert(_G._notify_msgs, msg) end
    -- Move focus to the prompt buffer so submit() finds the fixture instance.
    local inst = require('cc')._get_instance()
    vim.api.nvim_set_current_buf(inst.prompt.bufnr)
    -- Put some text in so the empty-buffer early-return doesn't apply.
    vim.api.nvim_buf_set_lines(inst.prompt.bufnr, 0, -1, false, { 'hello' })
    require('cc').submit()
  ]])
  local msgs = _G.child.lua_get('_G._notify_msgs')
  local found = false
  for _, m in ipairs(msgs) do
    if m:find('Viewing static fixture', 1, true) then found = true; break end
  end
  eq(found, true)
end

return T
