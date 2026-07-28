-- Icons for tool_use blocks and provider-aware UI.
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
  FileChange      = '\xef\x81\x80', -- U+F040 nf-fa-pencil (codex fileChange item)
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
  FileChange      = '✎',
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

-- Nerd Fonts 3.4/master has no OpenAI or Anthropic brand marks (checked July
-- 2026). These provider-specific stand-ins are intentionally paired with
-- distinct Unicode fallbacks below.
local PROVIDER_NERDFONT = {
  claude = '✻',
  codex  = '\xef\x84\xa0', -- U+F120 nf-fa-terminal 
}

local PROVIDER_UNICODE = {
  claude = '⁕',
  codex  = '›',
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

--- Return the model icon for a provider.
--- A configured provider value, including an empty string, takes precedence.
---@param provider string?
---@return string
function M.for_provider(provider)
  if type(provider) ~= 'string' or provider == '' then return '' end
  provider = provider:lower()
  local cfg = require('cc.config').options.statusline or {}
  local model_icons = cfg.model_icons or {}
  if model_icons[provider] ~= nil then return model_icons[provider] end
  local use_nerdfont = model_icons.use_nerdfont
  if use_nerdfont == nil then
    use_nerdfont = M.detect_nerdfont()
  end
  local set = use_nerdfont and PROVIDER_NERDFONT or PROVIDER_UNICODE
  return set[provider] or ''
end

-- Timing chunk icon (rendered between the tool summary and the elapsed-time
-- suffix). Nerdfont: nf-md-timer_outline (U+F051B 󰔛). Fallback: U+23F1 ⏱.
local TIMER_NF = '\xf3\xb0\x94\x9b'
local TIMER_FALLBACK = '\xe2\x8f\xb1'

--- Return the timing icon glyph appropriate for the active icon set.
---@return string
function M.timer_icon()
  local cfg = require('cc.config').options.tool_icons or {}
  local use_nerdfont = cfg.use_nerdfont
  if use_nerdfont == nil then
    use_nerdfont = M.detect_nerdfont()
  end
  return use_nerdfont and TIMER_NF or TIMER_FALLBACK
end

-- Exposed for tests / introspection.
M._NERDFONT = NERDFONT
M._UNICODE = UNICODE
M._PROVIDER_NERDFONT = PROVIDER_NERDFONT
M._PROVIDER_UNICODE = PROVIDER_UNICODE
M._TIMER_NF = TIMER_NF
M._TIMER_FALLBACK = TIMER_FALLBACK

return M
