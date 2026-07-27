local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T['resolve'] = MiniTest.new_set()

T['resolve']['keeps explicit executable paths direct'] = function()
  local Command = require('cc.command')
  local cmd, args = Command.resolve('/tmp/fake-claude', { '--version' })
  eq(cmd, '/tmp/fake-claude')
  eq(args, { '--version' })
end

T['resolve']['routes bare commands through a Bash login shell'] = function()
  local Command = require('cc.command')
  local old_shell = vim.env.SHELL
  vim.env.SHELL = '/bin/bash'
  local cmd, args = Command.resolve('cc', { '-p', 'hello world' })
  vim.env.SHELL = old_shell

  eq(cmd, '/bin/bash')
  eq(args[1], '-lc')
  eq(args[2], Command._bash_alias_runner)
  eq(args[3], 'cc.nvim')
  eq(args[4], 'cc')
  eq(args[5], '-p')
  eq(args[6], 'hello world')
end

T['bash alias runner'] = MiniTest.new_set()

T['bash alias runner']['prepends alias arguments and preserves caller arguments'] = function()
  local Command = require('cc.command')
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, 'p')
  local fake = tmp .. '/fake-claude'
  vim.fn.writefile({
    '#!/bin/bash',
    'printf "%s\\n" "$@"',
  }, fake)
  vim.fn.setfperm(fake, 'rwx------')

  local script = 'alias cc=' .. vim.fn.shellescape(fake .. ' --chrome') .. '\n'
    .. Command._bash_alias_runner
  local result = vim.system({
    '/bin/bash', '-c', script, 'cc.nvim', 'cc', '-p', 'hello world',
  }, { text = true }):wait()

  vim.fn.delete(tmp, 'rf')
  if result.code ~= 0 then error(vim.inspect(result)) end
  eq(result.code, 0)
  eq(result.stdout, '--chrome\n-p\nhello world\n')
end

return T
