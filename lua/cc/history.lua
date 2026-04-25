-- Session history: discover, list, read, format Claude Code session JSONL files.
--
-- Layout: ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
--   Encoded cwd: "/" -> "-" (e.g. /Users/foo/bar -> -Users-foo-bar)
-- Records of interest:
--   {"type":"user",         "message":{"role":"user", "content": "<str>" | [blocks...]}}
--   {"type":"assistant",    "message":{"role":"assistant", "content": [blocks...]}}
--   {"type":"custom-title", "customTitle":"<name>","sessionId":"..."} — user rename
--   {"type":"ai-title",     "aiTitle":"<name>","sessionId":"..."}     — AI-generated
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
      local meta = M._extract_metadata(path)
      -- Display title precedence: user custom-title > ai-title > first user message.
      local display = meta.custom_title or meta.ai_title or meta.first_prompt
      table.insert(entries, {
        session_id = session_id,
        path = path,
        mtime = stat.mtime.sec,
        size = stat.size,
        title = display or '(empty)',
        custom_title = meta.custom_title,
        ai_title = meta.ai_title,
        first_prompt = meta.first_prompt,
        cwd = meta.cwd,
      })
    end
  end
  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  return entries
end

--- Read session-level metadata from a JSONL without loading everything.
--- Scans the whole file (bounded by file size) so late renames win over early ones.
---@param path string
---@return { custom_title: string?, ai_title: string?, first_prompt: string?, cwd: string? }
function M._extract_metadata(path)
  local meta = {}
  local f = io.open(path, 'r')
  if not f then return meta end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == 'table' then
      if not meta.cwd and rec.cwd then meta.cwd = rec.cwd end
      if rec.type == 'custom-title' and type(rec.customTitle) == 'string' then
        -- Last write wins; empty string clears (matches Claude Code's behavior).
        if rec.customTitle == '' then
          meta.custom_title = nil
        else
          meta.custom_title = rec.customTitle
        end
      elseif rec.type == 'ai-title' and type(rec.aiTitle) == 'string' then
        meta.ai_title = rec.aiTitle
      elseif not meta.first_prompt and rec.type == 'user' and type(rec.message) == 'table' then
        local c = rec.message.content
        if type(c) == 'string' and c ~= '' then
          meta.first_prompt = c:gsub('\n', ' '):sub(1, 120)
        end
      end
    end
  end
  f:close()
  return meta
end

--- Resolve the JSONL path for a session in the given cwd.
---@param session_id string
---@param cwd string?
---@return string? path
function M.session_path(session_id, cwd)
  cwd = cwd or vim.fn.getcwd()
  local project_dir = PROJECTS_DIR .. '/' .. M.encode_cwd(cwd)
  local path = project_dir .. '/' .. session_id .. '.jsonl'
  local stat = vim.uv.fs_stat(path)
  if stat then return path end
  return nil
end

--- Append a `custom-title` entry to a session's JSONL. Matches Claude Code's
--- `saveCustomTitle` on-disk format so the TUI sees the rename.
--- Empty string clears the custom title (readers treat it as no-title).
---@param path string
---@param session_id string
---@param name string
---@return boolean ok, string? err
function M.append_custom_title(path, session_id, name)
  local f, err = io.open(path, 'a')
  if not f then return false, err end
  local rec = { type = 'custom-title', customTitle = name, sessionId = session_id }
  f:write(vim.json.encode(rec))
  f:write('\n')
  f:close()
  return true
end

---@class cc.HistoryEntry
---@field session_id string
---@field path string
---@field mtime integer
---@field size integer
---@field title string resolved display title (custom > ai > first prompt)
---@field custom_title string? user rename via /rename, if any
---@field ai_title string? AI-generated title, if any
---@field first_prompt string? first user-string message
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
---   { type='synthetic_notice', text=string }
---   { type='user_tool_result', tool_use_id=string, content=<str|array>, is_error=bool }
---   { type='assistant', blocks={<content blocks>} }
---@param path string
---@return table[]
function M.read_transcript(path)
  local out = {}
  local f = io.open(path, 'r')
  if not f then return out end
  local synthetic = require('cc.synthetic')
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == 'table' then
      local t = rec.type
      local msg = rec.message
      if t == 'user' and type(msg) == 'table' then
        local c = msg.content
        if type(c) == 'string' then
          local kind, payload = synthetic.classify(c)
          if kind == 'notice' then
            table.insert(out, { type = 'synthetic_notice', text = payload })
          else
            table.insert(out, { type = 'user_text', text = payload })
          end
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
---@return { input_tokens: integer, output_tokens: integer, cost_usd: number, model: string?, permission_mode: string?, custom_title: string?, ai_title: string? }
function M.read_session_meta(path)
  local meta = {
    input_tokens = 0,
    output_tokens = 0,
    cost_usd = 0,
    model = nil,
    permission_mode = nil,
    custom_title = nil,
    ai_title = nil,
  }
  local f = io.open(path, 'r')
  if not f then return meta end
  for line in f:lines() do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == 'table' then
      if rec.permissionMode then meta.permission_mode = rec.permissionMode end
      if rec.permission_mode then meta.permission_mode = rec.permission_mode end
      if rec.type == 'custom-title' and type(rec.customTitle) == 'string' then
        meta.custom_title = rec.customTitle ~= '' and rec.customTitle or nil
      elseif rec.type == 'ai-title' and type(rec.aiTitle) == 'string' then
        meta.ai_title = rec.aiTitle
      end
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
