-- Slash command discovery.
--   1. session.slash_commands (from system/init NDJSON) — authoritative list
--      for this session (built-ins + skills + MCP + custom commands)
--   2. ~/.claude/commands/*.md — descriptions + arguments docstrings
--   3. <cwd>/.claude/commands/*.md — project-level overrides
--   4. cc.nvim-native commands intercepted in init.lua M._try_handle_client_command
--      (not forwarded to the agent — they don't come from system/init).
-- Merged by name; descriptions from files preferred over bare init names.

local M = {}

---@class cc.SlashCmd
---@field name string
---@field description string?
---@field source string  'init' | 'user' | 'project' | 'client'

-- Client-side slash commands: handled by cc.nvim, not forwarded to the agent.
---@type cc.SlashCmd[]
local CLIENT_COMMANDS = {
  { name = 'rename', description = 'Rename the current conversation', source = 'client' },
}

--- Parse YAML-frontmatter `description` from a markdown file.
---@param path string
---@return string? description
local function parse_description(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local line = f:read('*l')
  if line ~= '---' then f:close(); return nil end
  local desc
  for _ = 1, 50 do
    line = f:read('*l')
    if not line or line == '---' then break end
    local d = line:match('^%s*description%s*:%s*(.+)%s*$')
    if d then
      desc = d:gsub('^"(.-)"$', '%1'):gsub("^'(.-)'$", '%1')
      break
    end
  end
  f:close()
  return desc
end

---@param dir string
---@param source string label for the source
---@param into table<string, cc.SlashCmd>
local function scan_dir(dir, source, into)
  if vim.fn.isdirectory(dir) ~= 1 then return end
  for _, p in ipairs(vim.fn.globpath(dir, '*.md', false, true)) do
    local name = vim.fn.fnamemodify(p, ':t:r')
    local desc = parse_description(p)
    into[name] = { name = name, description = desc, source = source }
  end
end

--- Build the merged list of slash commands for completion.
---@param session_commands string[]? list from system/init (may be nil)
---@return cc.SlashCmd[]
function M.list(session_commands)
  local byname = {}
  -- Start with bare init names so we still offer built-ins w/o descriptions.
  for _, n in ipairs(session_commands or {}) do
    byname[n] = { name = n, source = 'init' }
  end
  -- User commands override/augment.
  scan_dir(vim.fn.expand('~/.claude/commands'), 'user', byname)
  -- Project commands take final precedence.
  scan_dir(vim.fn.getcwd() .. '/.claude/commands', 'project', byname)
  -- cc.nvim client-side commands: only surfaced when not already claimed by
  -- the agent's slash_commands (so upstream wins if /rename becomes SDK-visible).
  for _, cmd in ipairs(CLIENT_COMMANDS) do
    if not byname[cmd.name] or byname[cmd.name].source == 'init' then
      byname[cmd.name] = cmd
    end
  end

  local list = {}
  for _, v in pairs(byname) do table.insert(list, v) end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

return M
