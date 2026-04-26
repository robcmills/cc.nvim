-- Splash screen for new instances. Renders as virt_lines above the first
-- buffer line, so the actual buffer stays empty and the existing
-- replace_empty rendering logic in output.lua is unaffected.

local M = {}

local NS = vim.api.nvim_create_namespace('cc.splash')

-- bufnr -> extmark id
local extmarks = {}

local function build_virt_lines()
  local Config = require('cc.config')
  local plugin_version = require('cc').VERSION or '?'

  local lines = {}
  local function add(...) table.insert(lines, { ... }) end
  -- local function blank() add({ '', 'Comment' }) end
  local function sep() add({ '───', 'NonText' }) end

  -- blank()
  add({ 'cc.nvim ' .. plugin_version .. ' 🦫', 'CcSplashTitle' })
  sep()

  add({ 'In prompt buffer (normal mode):', 'Comment' })
  local k = Config.options.keymaps
  add({ k.submit, 'CcSplashKey' }, { ' submit', 'Comment' })
  add({ k.interrupt, 'CcSplashKey' }, { ' interrupt', 'Comment' })

  sep()
  add({ k.goto_output, 'CcSplashKey' }, { ' focus output', 'Comment' })
  add({ k.goto_prompt, 'CcSplashKey' }, { ' focus prompt', 'Comment' })

  sep()
  local cmds = {
    { ':CcNew', 'Open cc.nvim (spawn process, create buffers)' },
    { ':CcClose', 'Close cc.nvim (kill process, close windows)' },
    { ':CcClear', 'Start a fresh session in the current windows' },
    { ':CcFold {n}', 'Set output fold level (0..3)' },
    { ':CcResume [id]', 'Resume a session (picker if no id)' },
    { ':CcRename [name]', 'Rename the current session (no arg = show current title)' },
  }
  for _, c in ipairs(cmds) do
    add({ c[1], 'CcSplashKey' }, { '  ' .. c[2], 'Comment' })
  end

  sep()
  add({ 'Hide this splash:', 'Comment' })
  add({ "require('cc').setup({ splash = false })", 'CcSplashKey' })

  return lines
end

---@param bufnr integer
function M.render(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not require('cc.config').options.splash then return end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ''
  if line_count > 1 or (line_count == 1 and first ~= '') then
    M.clear(bufnr)
    return
  end

  local opts = {
    virt_lines = build_virt_lines(),
    virt_lines_above = true,
  }
  local existing = extmarks[bufnr]
  if existing then opts.id = existing end
  extmarks[bufnr] = vim.api.nvim_buf_set_extmark(bufnr, NS, 0, 0, opts)
end

---@param bufnr integer
function M.clear(bufnr)
  if not bufnr then return end
  local id = extmarks[bufnr]
  if id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, id)
    extmarks[bufnr] = nil
  end
end

--- Re-render any active splashes (called when an async probe completes).
function M.refresh_all()
  for bufnr, _ in pairs(extmarks) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.render(bufnr)
    else
      extmarks[bufnr] = nil
    end
  end
end

return M
