-- Minimal init for cc.nvim testing with mini.test.
-- Usage: nvim --headless --clean -u tests/minimal_init.lua

-- Resolve paths relative to this file's directory
local this_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local repo_root = vim.fn.fnamemodify(this_dir, ':h')

-- Start from clean runtimepath (only nvim runtime + our plugins)
vim.opt.runtimepath = {
  repo_root,
  this_dir .. '/deps/mini.nvim',
  vim.env.VIMRUNTIME,
}

-- Disable swap/backup/undo to keep test env clean
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.undofile = false

-- Set a deterministic window size for screenshot tests
vim.o.lines = 30
vim.o.columns = 100

-- Store which init this is so test helpers can pass it to children
vim.g.cc_test_init = this_dir .. '/minimal_init.lua'

-- Load mini.test
require('mini.test').setup()
