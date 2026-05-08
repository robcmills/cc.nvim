-- Persistent metadata cache for history listings.
--
-- Avoids re-scanning every JSONL on every picker open. With ~hundreds of
-- sessions, _extract_metadata's full-file scan dominates the picker latency;
-- caching by (mtime, size) makes subsequent opens near-instant.
--
-- Layout: stdpath('cache')/cc-nvim/meta.json
-- Key:    absolute JSONL path
-- Stamp:  (mtime_sec, size) — mismatch invalidates the entry.
-- Bump VERSION when the cached schema changes.
--
-- Concurrent writers: atomic rename means no torn writes; last-writer-wins
-- on the rename. Lost entries are simply re-parsed next time.

local M = {}

local VERSION = 1

local default_path = vim.fn.stdpath('cache') .. '/cc-nvim/meta.json'
local cache_path = default_path

local loaded = false
local dirty = false
---@type table<string, { mtime: integer, size: integer, custom_title: string?, ai_title: string?, first_prompt: string?, cwd: string? }>
local entries = {}

local function load()
  if loaded then return end
  loaded = true
  if not vim.uv.fs_stat(cache_path) then return end
  local f = io.open(cache_path, 'r')
  if not f then return end
  local data = f:read('*a')
  f:close()
  local ok, decoded = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= 'table' then return end
  if decoded.version ~= VERSION then return end
  if type(decoded.entries) == 'table' then
    entries = decoded.entries
  end
end

--- Look up cached metadata for a path. Returns nil on miss (absent or stale).
---@param path string absolute path to a JSONL file
---@param stat table result of vim.uv.fs_stat(path)
---@return table? meta { custom_title?, ai_title?, first_prompt?, cwd? }
function M.get(path, stat)
  load()
  local e = entries[path]
  if not e then return nil end
  if e.mtime ~= stat.mtime.sec or e.size ~= stat.size then return nil end
  return {
    custom_title = e.custom_title,
    ai_title = e.ai_title,
    first_prompt = e.first_prompt,
    cwd = e.cwd,
  }
end

--- Record metadata for a path. Marks the cache dirty for the next flush().
---@param path string
---@param stat table
---@param meta { custom_title?: string, ai_title?: string, first_prompt?: string, cwd?: string }
function M.put(path, stat, meta)
  load()
  entries[path] = {
    mtime = stat.mtime.sec,
    size = stat.size,
    custom_title = meta.custom_title,
    ai_title = meta.ai_title,
    first_prompt = meta.first_prompt,
    cwd = meta.cwd,
  }
  dirty = true
end

--- Drop entries whose path is not in `live`. Caller is responsible for
--- ensuring `live` enumerates every currently-existing path; pass only when
--- you know you've seen them all (i.e. from list_all, not list_for_cwd).
---@param live table<string, true>
function M.prune(live)
  load()
  for path in pairs(entries) do
    if not live[path] then
      entries[path] = nil
      dirty = true
    end
  end
end

--- Atomically write the cache to disk if dirty. No-op otherwise.
function M.flush()
  if not dirty then return end
  local dir = vim.fn.fnamemodify(cache_path, ':h')
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, 'p')
  end
  local payload = vim.json.encode({ version = VERSION, entries = entries })
  local tmp = cache_path .. '.tmp'
  local f, err = io.open(tmp, 'w')
  if not f then
    vim.notify('cc.nvim: meta_cache write failed: ' .. tostring(err), vim.log.levels.WARN)
    return
  end
  f:write(payload)
  f:close()
  local ok, rename_err = vim.uv.fs_rename(tmp, cache_path)
  if not ok then
    vim.notify('cc.nvim: meta_cache rename failed: ' .. tostring(rename_err), vim.log.levels.WARN)
    os.remove(tmp)
    return
  end
  dirty = false
end

--- Test hook: override cache path and reset in-memory state.
---@param path string?
function M._reset_for_tests(path)
  cache_path = path or default_path
  loaded = false
  dirty = false
  entries = {}
end

return M
