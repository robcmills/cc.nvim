-- Rob's real config init for cc.nvim testing.
-- Sources ~/.config/nvim/init.lua to get the full environment:
-- tokyonight colorscheme, custom buffers sidebar, feline statusline,
-- packer plugins, nvim-cmp, treesitter, etc.
--
-- Usage: nvim --headless -u tests/rob_init.lua
-- Or: ./tests/run.sh --config=rob

-- Resolve paths
local this_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local nvim_config = vim.fn.expand('~/.config/nvim')

-- Add mini.nvim to rtp BEFORE sourcing Rob's config
vim.opt.runtimepath:prepend(this_dir .. '/deps/mini.nvim')

-- Add Rob's nvim config to rtp so require() finds his lua/ modules
vim.opt.runtimepath:prepend(nvim_config)

-- Also add the packer plugin paths so compiled plugins load
local packer_start = vim.fn.expand('~/.local/share/nvim/site/pack/packer/start')
local packer_opt = vim.fn.expand('~/.local/share/nvim/site/pack/packer/opt')
if vim.fn.isdirectory(packer_start) == 1 then
  for _, dir in ipairs(vim.fn.glob(packer_start .. '/*', false, true)) do
    vim.opt.runtimepath:append(dir)
  end
end
if vim.fn.isdirectory(packer_opt) == 1 then
  for _, dir in ipairs(vim.fn.glob(packer_opt .. '/*', false, true)) do
    vim.opt.runtimepath:append(dir)
  end
end

-- Disable swap/backup/undo for test env
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.undofile = false

-- Set a deterministic window size for screenshot tests
vim.o.lines = 30
vim.o.columns = 100

-- Source Rob's real init.lua
-- This loads packer, tokyonight, buffers.lua sidebar, feline, etc.
-- cc.nvim is already on rtp via Rob's init (runtimepath:prepend('~/src/cc.nvim'))
local rob_init = nvim_config .. '/init.lua'
if vim.fn.filereadable(rob_init) == 1 then
  -- Wrap in pcall so config errors don't prevent test execution
  local ok, err = pcall(vim.cmd, 'source ' .. rob_init)
  if not ok then
    io.stderr:write('rob_init.lua: error sourcing init.lua: ' .. tostring(err) .. '\n')
    io.stderr:write('Tests will run with partial config.\n')
  end
else
  vim.notify('rob_init.lua: ~/.config/nvim/init.lua not found, falling back to minimal', vim.log.levels.WARN)
  local repo_root = vim.fn.fnamemodify(this_dir, ':h')
  vim.opt.runtimepath:prepend(repo_root)
end

-- Store which init this is so test helpers can pass it to children
vim.g.cc_test_init = this_dir .. '/rob_init.lua'

-- Load mini.test after everything else
require('mini.test').setup()
