-- Reasoning effort level: persisted user preference applied to spawned
-- claude processes via the CLAUDE_CODE_EFFORT_LEVEL env var (read by the
-- claude CLI's effort resolver, see claude-code/src/utils/effort.ts).
--
-- Six levels match the upstream /effort menu: low | medium | high | xhigh |
-- max | auto. 'auto' means "let the model decide" — we omit the env var.

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
local loaded = false

local function state_paths()
  local dir = vim.fn.stdpath('data') .. '/cc.nvim'
  return dir, dir .. '/effort'
end

local function load()
  if loaded then return end
  loaded = true
  local _, path = state_paths()
  if vim.fn.filereadable(path) ~= 1 then return end
  local ok, lines = pcall(vim.fn.readfile, path, '', 1)
  local v = ok and lines and lines[1] or nil
  if v and LEVEL_SET[v] then current = v end
end

local function save()
  local dir, path = state_paths()
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, 'p')
  end
  pcall(vim.fn.writefile, { current }, path)
end

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
  load()
  return current
end

---@param v string
---@return boolean ok
function M.set(v)
  if not M.is_valid(v) then return false end
  load()
  current = v
  save()
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
  loaded = false
end

return M
