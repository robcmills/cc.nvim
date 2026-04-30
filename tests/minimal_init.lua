-- Minimal init for cc.nvim testing with mini.test.
-- Usage: nvim --headless --clean -u tests/minimal_init.lua

-- Resolve paths relative to this file's directory
local this_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local repo_root = vim.fn.fnamemodify(this_dir, ':h')

-- Start from clean runtimepath (only nvim runtime + our plugins). Include
-- the directory holding nvim's shipped tree-sitter parsers so tests that
-- exercise TS-backed code (e.g. cc.md_highlight) can find them. The
-- parsers ship at <prefix>/lib/nvim/parser/<lang>.so on macOS/Linux
-- builds, which is parallel to <prefix>/share/nvim/runtime (= VIMRUNTIME).
local function nvim_parser_dir()
  if vim.env.VIMRUNTIME and vim.env.VIMRUNTIME ~= '' then
    local prefix = vim.fn.fnamemodify(vim.env.VIMRUNTIME, ':h:h:h')
    local candidate = prefix .. '/lib/nvim'
    if vim.fn.isdirectory(candidate .. '/parser') == 1 then
      return candidate
    end
  end
  return nil
end

local rtp = {
  repo_root,
  this_dir .. '/deps/mini.nvim',
  vim.env.VIMRUNTIME,
}
local parser_dir = nvim_parser_dir()
if parser_dir then
  table.insert(rtp, parser_dir)
end
vim.opt.runtimepath = rtp

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
