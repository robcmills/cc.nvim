-- Highlight group defaults + buffer-local syntax for cc.nvim output.

local M = {}

--- Default highlight group linkages. Colorschemes can override by defining
--- any of these groups.
local defaults = {
  CcCaret     = { link = 'Comment' },
  CcUser      = { link = 'Function' },
  CcAgent     = { link = 'String' },
  CcTool      = { link = 'Identifier' },
  CcToolInput = { link = 'Normal' },
  CcOutput    = { link = 'Type' },
  CcError     = { link = 'ErrorMsg' },
  CcCost      = { link = 'Comment' },
  CcNotice    = { link = 'WarningMsg' },
  CcHook      = { link = 'Comment' },
  CcPermission = { link = 'WarningMsg' },
  CcDiffAdd    = { link = 'DiffAdd' },
  CcDiffDelete = { link = 'DiffDelete' },
  CcDiffHunk   = { link = 'DiffChange' },
  -- Statusline segments. Colors chosen to stay readable on typical dark
  -- backgrounds; override by defining these groups in your colorscheme.
  CcStl         = { fg = '#9aa5b1' },
  CcStlTokens   = { fg = '#a9e39a' }, -- light green
  CcStlMode     = { fg = '#e6c07b' }, -- yellow
  CcStlBranch   = { fg = '#c3a6ff' }, -- light purple
}

function M.set_defaults()
  for name, spec in pairs(defaults) do
    local existing = vim.api.nvim_get_hl(0, { name = name, link = false })
    -- Only set if not already defined (respects user overrides).
    if not existing or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', spec, { default = true }))
    end
  end
end

--- Apply buffer-local syntax matches so our tree gets colored.
---@param bufnr integer
function M.apply_buffer_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    -- Clear any prior cc syntax to avoid duplicates on reopen.
    pcall(vim.cmd, 'syntax clear CcUser CcAgent CcTool CcOutput CcError CcCost CcNotice CcHook CcPermission CcToolInput CcDiffAdd CcDiffDelete CcDiffHunk')

    -- containedin=ALL lets these matches override markdown regions (e.g.
    -- markdownCodeBlock opened by backticks in a tool result) that would
    -- otherwise engulf following header lines.
    vim.cmd([[syntax match CcUser    /^User:.*$/ containedin=ALL]])
    vim.cmd([[syntax match CcAgent   /^Agent:.*$/ containedin=ALL]])

    -- Tool header: "  <icon> <ToolName>: ..." — icon is one or more non-space
    -- glyphs, then a name starting with uppercase or the "mcp__" prefix,
    -- followed immediately by ":". Hook / Permission rules below override
    -- for lines that also match their own patterns.
    vim.cmd([[syntax match CcTool    /^\s\+\S\+\s\+\%(\u\w*\|mcp__\w\+\):.*$/ containedin=ALL]])

    -- Output: or Error: sub-headers under tools
    vim.cmd([[syntax match CcOutput  /^\s\+Output:\s*$/ containedin=ALL]])
    vim.cmd([[syntax match CcError   /^\s\+Error:\s*$/ containedin=ALL]])

    -- Cost / notice delineator lines: "  ── $0.05 ─"  "  ── Plan Mode ──"
    vim.cmd([[syntax match CcCost    /^\s*──.*──\s*$/ containedin=ALL]])

    -- Hook: dimmed event lines (match ⚙ Hook:)
    vim.cmd([[syntax match CcHook    /^\s\+⚙\s\+Hook:.*$/ containedin=ALL]])

    -- Permission request/outcome lines
    vim.cmd([[syntax match CcPermission /^\s\+[⚠✓✗]\s\+\%(Permission\|Allowed\|Denied\):.*$/ containedin=ALL]])

    -- Diff lines inside a tool input. These are always prefixed with exactly
    -- 8 spaces (see diff.lua INDENT), so we anchor on that to avoid matching
    -- markdown bullets in agent prose which use a shallower indent.
    vim.cmd([[syntax match CcDiffAdd    /^ \{8\}\zs+.*$/ containedin=ALL]])
    vim.cmd([[syntax match CcDiffDelete /^ \{8\}\zs-.*$/ containedin=ALL]])
    vim.cmd([[syntax match CcDiffHunk   /^ \{8\}\zs@@.*@@$/ containedin=ALL]])
  end)
end

return M
