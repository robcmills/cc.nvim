-- Reasoning effort level: an in-memory, session-scoped preference applied to
-- spawned claude processes via the CLAUDE_CODE_EFFORT_LEVEL env var (read by
-- the claude CLI's effort resolver, see claude-code/src/utils/effort.ts).
-- Deliberately not persisted to disk — it resets to the default on each
-- Neovim restart.
--
-- Six levels match the upstream /effort menu: low | medium | high | xhigh |
-- max | auto. 'auto' means "let the model decide" — we omit the env var, so
-- the CLI/model picks the default (e.g. 'high' on Opus 4.8).

local M = {}

local LEVELS = { 'low', 'medium', 'high', 'xhigh', 'max', 'auto' }
local LEVEL_SET = {}
for _, l in ipairs(LEVELS) do LEVEL_SET[l] = true end

local LABELS = {
  low    = 'low',
  medium = 'med',
  high   = 'high',
  xhigh  = 'xhigh',
  max    = 'max',
  auto   = 'auto',
}

-- Plain Unicode: filled-circle progression.
local UNICODE = {
  low    = '○',
  medium = '◔',
  high   = '◑',
  xhigh  = '◕',
  max    = '●',
  auto   = '◎',
}

-- Nerd Font: chess pieces (pawn → king, plus rook for auto).
local NERDFONT = {
  low    = '\xee\xb5\xa4', -- U+ED64 nf-fa-chess_pawn
  medium = '\xee\xb5\xa3', -- U+ED63 nf-fa-chess_knight
  high   = '\xee\xb5\xa0', -- U+ED60 nf-fa-chess_bishop
  xhigh  = '\xee\xb5\xa5', -- U+ED65 nf-fa-chess_queen
  max    = '\xee\xb5\xa2', -- U+ED62 nf-fa-chess_king
  auto   = '\xee\xb5\xa6', -- U+ED66 nf-fa-chess_rook
}

local current = 'auto'

---@return string[]
function M.levels()
  return vim.deepcopy(LEVELS)
end

---@param v any
---@return boolean
function M.is_valid(v)
  return type(v) == 'string' and LEVEL_SET[v] == true
end

---@return string current level
function M.get()
  return current
end

---@param v string
---@return boolean ok
function M.set(v)
  if not M.is_valid(v) then return false end
  current = v
  return true
end

local function use_nerdfont()
  local cfg = require('cc.config').options.tool_icons or {}
  local nf = cfg.use_nerdfont
  if nf == nil then nf = require('cc.icons').detect_nerdfont() end
  return nf and true or false
end

---@param level string?
---@return string
function M.symbol(level)
  level = level or M.get()
  if use_nerdfont() then return NERDFONT[level] or '' end
  return UNICODE[level] or ''
end

---@param level string?
---@return string
function M.label(level)
  level = level or M.get()
  return LABELS[level] or level
end

--- Build the env array for uv.spawn. If the current level is 'auto' we leave
--- the env var unset so the CLI/SDK falls back to the model default.
---@return string[]
function M.spawn_env()
  local env = vim.fn.environ()
  local cur = M.get()
  if cur and cur ~= 'auto' then
    env.CLAUDE_CODE_EFFORT_LEVEL = cur
  else
    env.CLAUDE_CODE_EFFORT_LEVEL = nil
  end
  local arr = {}
  for k, v in pairs(env) do
    table.insert(arr, k .. '=' .. v)
  end
  return arr
end

-- Test helpers.
M._UNICODE = UNICODE
M._NERDFONT = NERDFONT
M._LABELS = LABELS
function M._reset()
  current = 'auto'
end

return M
