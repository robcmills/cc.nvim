-- Buffer-local navigation keymaps on the prompt/output pair.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

--- Swap in an in-process claude provider so `open` builds the real layout
--- without a subprocess.
local INSTALL_FAKE = [==[
  _G._orig_claude = package.loaded['cc.providers.claude']
  local fake = { name = 'claude', capabilities = { auto_rename = false } }
  fake.options = function() return {} end
  fake.attach = function(ctx)
    local p = { name = 'claude', capabilities = fake.capabilities, opts = { cwd = ctx.cwd }, alive = true }
    function p:spawn() end
    function p:is_alive() return self.alive end
    function p:close() self.alive = false end
    function p:send() end
    return p
  end
  package.loaded['cc.providers.claude'] = fake
  require('cc.config').setup({})
]==]

local RESTORE_FAKE = [==[
  package.loaded['cc.providers.claude'] = _G._orig_claude
]==]

-- Reopening a session can put focus in the output window. The builtin `go`
-- jumps to byte 1, so pressing goto_output there used to yank a tailing
-- view to the top of the session.
T['goto_output pressed in the output keeps the cursor and view'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    vim.cmd('enew')
    local bufnr = cc.open()
    vim.cmd('stopinsert')
    local inst = cc.find_instance(bufnr)
    local lines = {}
    for i = 1, 200 do lines[i] = 'line ' .. i end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_set_current_win(inst.output_winid)
    vim.cmd('normal! Gzb')
    _G._win = inst.output_winid
  ]==] .. RESTORE_FAKE)
  local before = _G.child.lua_get('vim.api.nvim_win_call(_G._win, vim.fn.winsaveview)')
  eq(before.lnum, 200)
  _G.child.type_keys('go')
  local after = _G.child.lua_get('vim.api.nvim_win_call(_G._win, vim.fn.winsaveview)')
  eq(_G.child.lua_get('vim.api.nvim_get_current_win() == _G._win'), true)
  eq(after.lnum, before.lnum)
  eq(after.topline, before.topline)
end

T['goto_output from the prompt focuses the output'] = function()
  _G.child.lua(INSTALL_FAKE .. [==[
    local cc = require('cc')
    vim.cmd('enew')
    local bufnr = cc.open()
    vim.cmd('stopinsert')
    _G._win = cc.find_instance(bufnr).output_winid
  ]==] .. RESTORE_FAKE)
  _G.child.type_keys('go')
  eq(_G.child.lua_get('vim.api.nvim_get_current_win() == _G._win'), true)
end

return T
