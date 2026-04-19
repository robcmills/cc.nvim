-- Session history: discover, list, read, format Claude Code session JSONL files.
--
-- Layout: ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
--   Encoded cwd: "/" -> "-" (e.g. /Users/foo/bar -> -Users-foo-bar)
-- Records of interest:
--   {"type":"user",      "message":{"role":"user", "content": "<str>" | [blocks...]}}
--   {"type":"assistant", "message":{"role":"assistant", "content": [blocks...]}}
-- Other record types (snapshots, hooks, system, permission-mode) are skipped.

local M = {}

local PROJECTS_DIR = vim.fn.expand('~/.claude/projects')

--- Encode a cwd path to a CC project directory name.
--- Both '/' and '.' are replaced with '-' (e.g. /Users/a/cc.nvim -> -Users-a-cc-nvim).
---@param cwd string
---@return string
function M.encode_cwd(cwd)
  return (cwd:gsub('[/.]', '-'))
end

--- Decode a project dir name back to an approximate path.
--- (Best-effort only — CC's encoding is lossy; we can't tell '-' from '/' or '.'.)
---@param encoded string
---@return string
function M.decode_cwd(encoded)
  return (encoded:gsub('^%-', '/'):gsub('%-', '/'))
end

---@return string projects_dir absolute path to ~/.claude/projects
function M.projects_dir()
  return PROJECTS_DIR
end

--- Scan a project directory for session JSONL files, return metadata sorted
--- by mtime desc.
---@param project_dir string
---@return cc.HistoryEntry[]
local function list_in_dir(project_dir)
  local entries = {}
  local files = vim.fn.globpath(project_dir, '*.jsonl', false, true)
  for _, path in ipairs(files) do
    local stat = vim.uv.fs_stat(path)
    if stat then
      local session_id = vim.fn.fnamemodify(path, ':t:r')
      -- Title = first user-string message; pulled from the file.
      local title, cwd = M._extract_metadata(path)
      table.insert(entries, {
        session_id = session_id,
        path = path,
        mtime = stat.mtime.sec,
        size = stat.size,
        title = title or '(empty)',
        cwd = cwd,
      })
    end
  end
  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  return entries
end

--- Read the first user-string message + cwd from a JSONL without loading everything.
---@param path string
---@return string? title, string? cwd
function M._extract_metadata(path)
  local f = io.open(path, 'r')
  if not f then return nil, nil end
  local title, cwd
  -- Read up to 200 lines or until we have both.
  for _ = 1, 200 do
    local line = f:read('*l')
    if not line then break end
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == 'table' then
      if not cwd and rec.cwd then cwd = rec.cwd end
      if not title and rec.type == 'user' and type(rec.message) == 'table' then
        local c = rec.message.content
        if type(c) == 'string' and c ~= '' then
          title = c:gsub('\n', ' '):sub(1, 120)
        end
      end
      if title and cwd then break end
    end
  end
  f:close()
  return title, cwd
end

---@class cc.HistoryEntry
---@field session_id string
---@field path string
---@field mtime integer
---@field size integer
---@field title string
---@field cwd string?

--- List sessions for the given cwd (defaults to vim.fn.getcwd()).
---@param cwd string?
---@return cc.HistoryEntry[]
function M.list_for_cwd(cwd)
  cwd = cwd or vim.fn.getcwd()
  local project_dir = PROJECTS_DIR .. '/' .. M.encode_cwd(cwd)
  if vim.fn.isdirectory(project_dir) ~= 1 then return {} end
  return list_in_dir(project_dir)
end

--- List sessions across all projects.
---@return cc.HistoryEntry[]
function M.list_all()
  if vim.fn.isdirectory(PROJECTS_DIR) ~= 1 then return {} end
  local all = {}
  local dirs = vim.fn.glob(PROJECTS_DIR .. '/*', false, true)
  for _, d in ipairs(dirs) do
    if vim.fn.isdirectory(d) == 1 then
      for _, e in ipairs(list_in_dir(d)) do table.insert(all, e) end
    end
  end
  table.sort(all, function(a, b) return a.mtime > b.mtime end)
  return all
end

--- Read an entire session transcript, returning records we care about in order.
--- Each returned record is one of:
---   { type='user_text', text=string }
---   { type='user_tool_result', tool_use_id=string, content=<str|array>, is_error=bool }
---   { type='assistant', blocks={<content blocks>} }
---@param path string
---@return table[]
function M.read_transcript(path)
  local out = {}
  local f = io.open(path, 'r')
  if not f then return out end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == 'table' then
      local t = rec.type
      local msg = rec.message
      if t == 'user' and type(msg) == 'table' then
        local c = msg.content
        if type(c) == 'string' then
          table.insert(out, { type = 'user_text', text = c })
        elseif type(c) == 'table' then
          for _, block in ipairs(c) do
            if type(block) == 'table' and block.type == 'tool_result' then
              table.insert(out, {
                type = 'user_tool_result',
                tool_use_id = block.tool_use_id,
                content = block.content,
                is_error = block.is_error,
              })
            end
          end
        end
      elseif t == 'assistant' and type(msg) == 'table' then
        if type(msg.content) == 'table' then
          table.insert(out, { type = 'assistant', blocks = msg.content })
        end
      end
    end
  end
  f:close()
  return out
end

--- Scan a transcript file for cumulative session metadata: aggregate token
--- usage across all assistant records, plus model and permission_mode last
--- observed. Used by resume to seed the statusline before the subprocess
--- has emitted its system:init.
---@param path string
---@return { input_tokens: integer, output_tokens: integer, cost_usd: number, model: string?, permission_mode: string? }
function M.read_session_meta(path)
  local meta = {
    input_tokens = 0,
    output_tokens = 0,
    cost_usd = 0,
    model = nil,
    permission_mode = nil,
  }
  local f = io.open(path, 'r')
  if not f then return meta end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == 'table' then
      if rec.permissionMode then meta.permission_mode = rec.permissionMode end
      if rec.permission_mode then meta.permission_mode = rec.permission_mode end
      local msg = rec.message
      if type(msg) == 'table' then
        if msg.model then meta.model = msg.model end
        local usage = msg.usage
        if type(usage) == 'table' then
          meta.input_tokens = meta.input_tokens + (usage.input_tokens or 0)
          meta.output_tokens = meta.output_tokens + (usage.output_tokens or 0)
        end
      end
      if type(rec.costUSD) == 'number' then
        meta.cost_usd = meta.cost_usd + rec.costUSD
      end
    end
  end
  f:close()
  return meta
end

--- Format a history entry for a picker line.
---@param entry cc.HistoryEntry
---@param show_cwd boolean
---@return string
function M.format_entry(entry, show_cwd)
  local age = M._relative_time(entry.mtime)
  local cwd_abbrev = ''
  if show_cwd and entry.cwd then
    cwd_abbrev = vim.fn.fnamemodify(entry.cwd, ':~')
    if #cwd_abbrev > 30 then
      cwd_abbrev = '…' .. cwd_abbrev:sub(-29)
    end
    cwd_abbrev = string.format('%-30s  ', cwd_abbrev)
  end
  local title = entry.title or ''
  if #title > 80 then title = title:sub(1, 79) .. '…' end
  return string.format('%-10s %s%s', age, cwd_abbrev, title)
end

---@param mtime integer unix epoch seconds
---@return string
function M._relative_time(mtime)
  local now = os.time()
  local delta = now - mtime
  if delta < 60 then return delta .. 's ago' end
  if delta < 3600 then return math.floor(delta / 60) .. 'm ago' end
  if delta < 86400 then return math.floor(delta / 3600) .. 'h ago' end
  if delta < 86400 * 30 then return math.floor(delta / 86400) .. 'd ago' end
  return os.date('%Y-%m-%d', mtime)
end

return M
