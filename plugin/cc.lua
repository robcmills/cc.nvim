-- cc.nvim autoload: register user commands once.

if vim.g.loaded_cc_nvim then
  return
end
vim.g.loaded_cc_nvim = 1

require('cc.commands').create()

-- Default highlight groups (link to existing groups so colorschemes drive them).
require('cc.highlight').set_defaults()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('cc.highlights', { clear = true }),
  callback = function() require('cc.highlight').set_defaults() end,
})

-- Register nvim-cmp source for slash command completion if nvim-cmp is loaded.
-- Safe no-op otherwise; users without nvim-cmp get the omnifunc fallback
-- configured on the prompt buffer by cc.prompt.
local ok_cmp, cmp = pcall(require, 'cmp')
if ok_cmp then
  pcall(cmp.register_source, 'cc_slash', require('cc.cmp_source').new())
end
