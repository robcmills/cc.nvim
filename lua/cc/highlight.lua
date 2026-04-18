-- Highlight group defaults + buffer-local syntax for cc.nvim output.

local M = {}

--- Default highlight group linkages. Colorschemes can override by defining
--- any of these groups.
local defaults = {
  CcCaret     = { link = 'Comment' },
  CcSpinner   = { link = 'Comment' },
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

    -- User: / Agent: headers (allow extended content after the colon for folded summaries).
    vim.cmd([[syntax match CcUser    /^User:.*$/]])
    vim.cmd([[syntax match CcAgent   /^Agent:.*$/]])

    -- Tool header: "  <icon> <ToolName>: ..." — icon is one or more non-space
    -- glyphs, then a name starting with uppercase or the "mcp__" prefix,
    -- followed immediately by ":". Hook / Permission rules below override
    -- for lines that also match their own patterns.
    vim.cmd([[syntax match CcTool    /^\s\+\S\+\s\+\%(\u\w*\|mcp__\w\+\):.*$/]])

    -- Output: or Error: sub-headers under tools
    vim.cmd([[syntax match CcOutput  /^\s\+Output:\s*$/]])
    vim.cmd([[syntax match CcError   /^\s\+Error:\s*$/]])

    -- Cost / notice delineator lines: "  ── $0.05 ─"  "  ── Plan Mode ──"
    vim.cmd([[syntax match CcCost    /^\s*──.*──\s*$/]])

    -- Hook: dimmed event lines (match ⚙ Hook:)
    vim.cmd([[syntax match CcHook    /^\s\+⚙\s\+Hook:.*$/]])

    -- Permission request/outcome lines
    vim.cmd([[syntax match CcPermission /^\s\+[⚠✓✗]\s\+\%(Permission\|Allowed\|Denied\):.*$/]])

    -- Diff lines inside a tool input. The first non-whitespace char after the
    -- indent is -, +, or @. Use very-magic and make sure we don't match the
    -- tool header (Tool:) accidentally.
    vim.cmd([[syntax match CcDiffAdd    /^\s\+\zs+.*$/]])
    vim.cmd([[syntax match CcDiffDelete /^\s\+\zs-.*$/]])
    vim.cmd([[syntax match CcDiffHunk   /^\s\+\zs@@.*@@$/]])
  end)
end

return M
