-- Tool icons: resolve a glyph for a tool_use block.
-- Defaults come in two flavours: nerdfont (when the user has a nerdfont plugin
-- like nvim-web-devicons or mini.icons installed) and plain Unicode fallbacks.
-- Users can override per-tool icons and the global default in config.tool_icons.

local M = {}

-- Nerdfont glyphs, encoded as UTF-8 escapes so this file has no dependency on
-- a particular editor / font. Codepoints are chosen from common nf-* names.
local NERDFONT = {
  Read            = '\xef\x80\xad', -- U+F02D nf-fa-book 
  Edit            = '\xef\x81\x80', -- U+F040 nf-fa-pencil 
  MultiEdit       = '\xef\x81\x80', -- U+F040 nf-fa-pencil 
  Write           = '\xef\x85\x9b', -- U+F15B nf-fa-file 
  NotebookEdit    = '\xef\x85\x9b', -- U+F15B nf-fa-file
  Bash            = '\xef\x84\xa0', -- U+F120 nf-fa-terminal 
  Grep            = '\xef\x80\x82', -- U+F002 nf-fa-search 
  Glob            = '\xef\x80\x82', -- U+F002 nf-fa-search 
  WebFetch        = '\xef\x82\xac', -- U+F0AC nf-fa-globe 
  WebSearch       = '\xef\x80\x82', -- U+F002 nf-fa-search 
  TodoWrite       = '\xef\x80\xba', -- U+F03A nf-fa-list 
  Agent           = '\xf3\xb0\x8b\x98', -- U+F02D8 nf-md-robot_outline 󰋘
  Task            = '\xef\x80\x8c', -- U+F00C nf-fa-check 
  Skill           = '\xef\x83\x90', -- U+F0D0 nf-fa-magic 
  AskUserQuestion = '\xef\x84\xa8', -- U+F128 nf-fa-question 
  EnterPlanMode   = '\xef\x89\xb9', -- U+F279 nf-fa-map 
  ExitPlanMode    = '\xef\x80\x8c', -- U+F00C nf-fa-check 
  default         = '\xef\x82\xad', -- U+F0AD nf-fa-wrench 
}

-- Plain Unicode fallbacks (render in any terminal without a patched font).
local UNICODE = {
  Read            = '▤',
  Edit            = '✎',
  MultiEdit       = '✎',
  Write           = '✎',
  NotebookEdit    = '✎',
  Bash            = '❯',
  Grep            = '⌕',
  Glob            = '⌕',
  WebFetch        = '⊜',
  WebSearch       = '⌕',
  TodoWrite       = '☰',
  Agent           = '⬢',
  Task            = '☑',
  Skill           = '✦',
  AskUserQuestion = '?',
  EnterPlanMode   = '▣',
  ExitPlanMode    = '▣',
  default         = '◆',
}

-- Detect whether a nerdfont-aware icon plugin is loaded.
-- Returns true if nvim-web-devicons or mini.icons is require-able.
---@return boolean
function M.detect_nerdfont()
  if pcall(require, 'nvim-web-devicons') then return true end
  if pcall(require, 'mini.icons') then return true end
  return false
end

-- Resolve which icon set (nerdfont or unicode) to use, based on config.
---@return table<string, string> icon_table
function M.icon_set()
  local cfg = require('cc.config').options.tool_icons or {}
  local use_nerdfont = cfg.use_nerdfont
  if use_nerdfont == nil then
    use_nerdfont = M.detect_nerdfont()
  end
  return use_nerdfont and NERDFONT or UNICODE
end

-- Return the icon glyph for a given tool name.
-- Precedence: user icons[tool] > icon_set[tool] > user default > icon_set.default.
---@param tool_name string
---@return string
function M.for_tool(tool_name)
  local cfg = require('cc.config').options.tool_icons or {}
  local user_icons = cfg.icons or {}
  if user_icons[tool_name] then return user_icons[tool_name] end
  local set = M.icon_set()
  if set[tool_name] then return set[tool_name] end
  if cfg.default and cfg.default ~= '' then return cfg.default end
  return set.default
end

-- Exposed for tests / introspection.
M._NERDFONT = NERDFONT
M._UNICODE = UNICODE

return M
