-- Highlight group defaults + buffer-local syntax for cc.nvim output.

local M = {}

--- Default highlight group linkages. Colorschemes can override by defining
--- any of these groups.
local defaults = {
  CcCaret     = { link = 'Comment' },
  CcUser      = { link = 'Function' },
  CcAgent     = { link = 'String' },
  CcTool      = { link = 'Constant' },
  CcToolInput = { link = 'Normal' },
  CcToolTiming = { fg = '#9aa5b1' },
  CcOutput    = { link = 'Type' },
  CcError     = { link = 'ErrorMsg' },
  CcCost      = { link = 'Comment' },
  CcThinking  = { link = 'Comment' },
  CcNotice    = { link = 'WarningMsg' },
  CcHook      = { link = 'Comment' },
  CcPermission = { link = 'WarningMsg' },
  CcDiffAdd    = { link = 'DiffAdd' },
  CcDiffDelete = { link = 'DiffDelete' },
  CcDiffHunk   = { link = 'DiffChange' },
  -- TodoWrite item status icons
  CcTodoCompleted  = { fg = '#a9e39a' }, -- light green
  CcTodoInProgress = { fg = '#e6c07b' }, -- warm yellow
  CcTodoIncomplete = { link = 'Comment' },
  -- Statusline segments. Colors chosen to stay readable on typical dark
  -- backgrounds; override by defining these groups in your colorscheme.
  CcStl         = { fg = '#9aa5b1' },
  CcStlTokens   = { fg = '#a9e39a' }, -- light green
  CcStlMode     = { fg = '#e6c07b' }, -- yellow (warm/orange-ish)
  CcStlEffort   = { fg = '#ece95a' }, -- yellow (cool, clearly distinct from mode)
  CcStlBranch   = { fg = '#c3a6ff' }, -- light purple
  CcStlSession  = { fg = '#8ecae6' }, -- light blue
  -- Splash screen
  CcSplashTitle = { fg = '#fff066', bold = true }, -- bright yellow
  CcSplashKey   = { fg = '#c8a165' },               -- light brown
  -- :CcStatus floating window
  CcStatusNormal  = { link = 'NormalFloat' },
  CcStatusBorder  = { link = 'FloatBorder' },
  CcStatusTitle   = { fg = '#fff066', bold = true }, -- bright yellow (matches splash)
  CcStatusSection = { fg = '#ffb86b', bold = true }, -- light orange
  CcStatusLabel   = { link = 'Comment' },
  CcStatusValue   = { link = 'Normal' },
  CcStatusDim     = { link = 'Comment' },
  CcStatusOK      = { fg = '#a9e39a' }, -- light green
  CcStatusWarn    = { fg = '#e6c07b' }, -- warm yellow
  -- Prompt buffer placeholder text (when empty)
  CcPromptPlaceholder = { link = 'Comment' },
}

function M.set_defaults()
  for name, spec in pairs(defaults) do
    local existing = vim.api.nvim_get_hl(0, { name = name, link = false })
    -- Only set if not already defined (respects user overrides).
    if not existing or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, name, vim.tbl_extend('keep', spec, { default = true }))
    end
  end

  -- CcFolded: if the user provided highlights.fold in setup(), apply it
  -- unconditionally (user override wins over colorschemes). Otherwise
  -- seed a default spec that colorschemes can still override.
  local ok, config = pcall(require, 'cc.config')
  local user_fold = ok and config.options.highlights and config.options.highlights.fold or nil
  if user_fold then
    vim.api.nvim_set_hl(0, 'CcFolded', user_fold)
  else
    local existing = vim.api.nvim_get_hl(0, { name = 'CcFolded', link = false })
    if not existing or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, 'CcFolded', { bg = 'NONE', default = true })
    end
  end
end

--- Apply buffer-local syntax matches so our tree gets colored.
---@param bufnr integer
function M.apply_buffer_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    -- Clear any prior cc syntax to avoid duplicates on reopen.
    pcall(vim.cmd, 'syntax clear CcUser CcAgent CcTool CcOutput CcError CcCost CcThinking CcNotice CcHook CcPermission CcToolInput CcToolTiming CcDiffAdd CcDiffDelete CcDiffHunk CcTodoCompleted CcTodoInProgress CcTodoIncomplete')

    -- Filetype is cc-output so vim's runtime markdown.vim/html.vim shouldn't
    -- load on its own. But user plugins occasionally `runtime! syntax/html.vim`
    -- or otherwise pull html groups into the global syntax registry, where
    -- they then match in our buffer. html.vim defines a "bogus comment"
    -- region (start `<!`, end `>`) that paints intervening content as
    -- htmlCommentError → Error (red), so a Bash command like `... 2>&1`
    -- after a stray `<!` ends up red. Defense in depth: clear html groups
    -- if they were registered.
    pcall(vim.cmd, 'syntax clear htmlComment htmlCommentError htmlCommentNested htmlTag htmlEndTag htmlError htmlTagError htmlPreProc htmlPreError htmlPreAttr htmlPreStmt htmlPreProcAttrName htmlPreProcAttrError htmlSpecialChar htmlString htmlTagName htmlSpecialTagName htmlArg htmlValue htmlEvent htmlScriptTag htmlMath htmlSvg htmlMathTagName htmlSvgTagName htmlLink htmlH1 htmlH2 htmlH3 htmlH4 htmlH5 htmlH6 htmlHead htmlTitle htmlBold htmlItalic htmlStrike htmlUnderline htmlBoldItalic htmlBoldUnderline htmlBoldUnderlineItalic htmlItalicBold htmlItalicUnderline htmlItalicBoldUnderline htmlItalicUnderlineBold htmlUnderlineBold htmlUnderlineItalic htmlUnderlineBoldItalic htmlUnderlineItalicBold htmlLeadingSpace htmlCssDefinition htmlCssStyleComment cssStyle javaScript javaScriptExpression javaScriptNumber')

    -- containedin=ALL lets these matches override markdown regions (e.g.
    -- markdownCodeBlock opened by backticks in a tool result) that would
    -- otherwise engulf following header lines.
    vim.cmd([[syntax match CcUser    /^User:.*$/ containedin=ALL]])
    vim.cmd([[syntax match CcAgent   /^Agent:.*$/ containedin=ALL]])

    -- Tool header: "  <icon> <ToolName>: ..." — icon is one or more non-space
    -- glyphs, then a name starting with uppercase or the "mcp__" prefix,
    -- followed immediately by ":". Hook / Permission rules below override
    -- for lines that also match their own patterns.
    vim.cmd([[syntax match CcTool    /^\s\+\S\+\s\+\%(\u\w*\|mcp__[[:alnum:]_-]\+\):.*$/ containedin=ALL]])

    -- Tool timing chunk: "  ▶ Bash: cmd 󰔛 5s (timeout 30s)"
    -- Matches from the timer icon (nerdfont 󰔛 or unicode ⏱) to end of line.
    -- Declared after CcTool so it overrides that match for the timing chunk.
    vim.cmd([[syntax match CcToolTiming /\%(󰔛\|⏱\).*$/ containedin=ALL]])

    -- Output: or Error: sub-headers under tools
    vim.cmd([[syntax match CcOutput  /^\s\+Output:\s*$/ containedin=ALL]])
    vim.cmd([[syntax match CcError   /^\s\+Error:\s*$/ containedin=ALL]])

    -- Cost / notice delineator lines: "  ── $0.05 ─"  "  ── Plan Mode ──"
    vim.cmd([[syntax match CcCost    /^\s*──.*──\s*$/ containedin=ALL]])

    -- Thinking header + inline content: "  ∴ Thinking... <text>"
    vim.cmd([[syntax match CcThinking /^\s\+∴\s\+Thinking\.\.\..*$/ containedin=ALL]])

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

    -- TodoWrite item icons. Glyphs must match output.lua's todo_marker().
    vim.cmd([[syntax match CcTodoCompleted  /^\s\+\zs✓\ze\s/ containedin=ALL]])
    vim.cmd([[syntax match CcTodoInProgress /^\s\+\zs◐\ze\s/ containedin=ALL]])
    vim.cmd([[syntax match CcTodoIncomplete /^\s\+\zs□\ze\s/ containedin=ALL]])
  end)
end

return M
