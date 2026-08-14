-- Model catalogs fetched from the provider CLIs (:CcModelsUpdate).
--
-- The CLIs themselves are the source of truth for which models exist:
-- Claude answers the `list_models` stream-json control_request with the
-- same catalog its /model picker shows (filtered by subscription and
-- settings), and Codex answers the `model/list` JSON-RPC method. Results
-- are normalized into one JSON cache file so :CcModel/:CcNew completion
-- (cc.model) works without a running session. The cache is refreshed only
-- by :CcModelsUpdate — never in the background. A live session's
-- subprocess is reused when one exists; otherwise a short-lived one is
-- spawned on libuv pipes and terminated after the response, so the editor
-- never blocks.

local M = {}

local FETCH_TIMEOUT_MS = 30000

---@class cc.ModelEntry
---@field name string model id/alias exactly as accepted by the CLI
---@field display string? provider-reported display name
---@field efforts string[]? supported reasoning effort levels
---@field default boolean? provider-reported default model

--- Cache file path. `config.models_path` overrides the default under
--- stdpath('data').
---@return string
function M.path()
  local configured = require('cc.config').options.models_path
  if type(configured) == 'string' and configured ~= '' then
    return vim.fn.expand(configured)
  end
  return vim.fn.stdpath('data') .. '/cc/models.json'
end

local _cache ---@type { path: string, data: table }?

function M.invalidate()
  _cache = nil
end

--- Decoded cache file, or nil when absent or unreadable.
---@return { version: integer?, updated_at: integer?, providers: table<string, cc.ModelEntry[]> }?
function M.load()
  local path = M.path()
  if _cache and _cache.path == path then return _cache.data end
  local file = io.open(path, 'r')
  if not file then return nil end
  local content = file:read('*a')
  file:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' or type(data.providers) ~= 'table' then
    return nil
  end
  _cache = { path = path, data = data }
  return data
end

--- Cached model entries for one provider (empty when never updated).
---@param provider string
---@return cc.ModelEntry[]
function M.cached(provider)
  local data = M.load()
  local entries = data and data.providers[provider]
  if type(entries) ~= 'table' then return {} end
  local out = {}
  for _, entry in ipairs(entries) do
    if type(entry) == 'table' and type(entry.name) == 'string' and entry.name ~= '' then
      table.insert(out, entry)
    end
  end
  return out
end

---@param data table
---@return boolean ok
---@return string? err
local function write_cache(data)
  local path = M.path()
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, 'p') == 0 then
    return false, 'could not create ' .. dir
  end
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then return false, tostring(encoded) end
  local file, err = io.open(path, 'w')
  if not file then return false, tostring(err) end
  file:write(encoded)
  file:close()
  M.invalidate()
  return true
end

--- Normalize a Claude `list_models` catalog. The 'default' pseudo-entry is
--- a picker affordance, not a selectable model name, so it is skipped.
---@param models table[]?
---@return cc.ModelEntry[]
function M._from_claude(models)
  local entries = {}
  for _, m in ipairs(models or {}) do
    if type(m) == 'table' and type(m.value) == 'string'
        and m.value ~= '' and m.value ~= 'default' then
      table.insert(entries, {
        name = m.value,
        display = type(m.displayName) == 'string' and m.displayName or nil,
        efforts = type(m.supportedEffortLevels) == 'table'
          and #m.supportedEffortLevels > 0 and m.supportedEffortLevels or nil,
      })
    end
  end
  return entries
end

--- Normalize a Codex `model/list` result, dropping models the CLI hides
--- from its own picker.
---@param data table[]?
---@return cc.ModelEntry[]
function M._from_codex(data)
  local entries = {}
  for _, m in ipairs(data or {}) do
    if type(m) == 'table' and type(m.id) == 'string' and m.id ~= ''
        and m.hidden ~= true then
      local efforts = {}
      for _, e in ipairs(m.supportedReasoningEfforts or {}) do
        if type(e) == 'table' and type(e.reasoningEffort) == 'string' then
          table.insert(efforts, e.reasoningEffort)
        end
      end
      table.insert(entries, {
        name = m.id,
        display = type(m.displayName) == 'string' and m.displayName or nil,
        efforts = #efforts > 0 and efforts or nil,
        default = m.isDefault == true or nil,
      })
    end
  end
  return entries
end

--- Wrap a completion callback so only the first outcome wins and cleanup
--- runs exactly once. Every fetch path has multiple possible terminations
--- (response, process exit, timeout) racing on the main loop.
---@param cleanup fun()?
---@param done fun(entries: cc.ModelEntry[]?, err: string?)
---@return fun(entries: cc.ModelEntry[]?, err: string?)
local function once(cleanup, done)
  local finished = false
  return function(entries, err)
    if finished then return end
    finished = true
    if cleanup then pcall(cleanup) end
    done(entries, err)
  end
end

---@param done fun(entries: cc.ModelEntry[]?, err: string?)
local function fetch_claude(done)
  local inst = require('cc')._find_live_instance('claude')
  if inst and inst.process and inst.process.send_control_list_models then
    local finish = once(nil, done)
    local request_id = inst.process:send_control_list_models(function(ok, resp)
      if not ok then
        finish(nil, tostring(resp and resp.error or 'request failed'))
        return
      end
      finish(M._from_claude(resp.response and resp.response.models))
    end)
    if request_id then
      vim.defer_fn(function() finish(nil, 'timed out') end, FETCH_TIMEOUT_MS)
      return
    end
  end

  -- No live session: spawn a short-lived CLI, ask, terminate. The process
  -- idles awaiting stream-json input, so only the control channel is used.
  local proc
  local finish = once(function() if proc then proc:close() end end, done)
  proc = require('cc.process').new({
    cmd = require('cc.providers.claude').options().cmd,
    on_message = function(msg)
      if msg.type ~= 'control_response' then return end
      local resp = msg.response or {}
      local entry = resp.request_id
        and proc:consume_pending_control_entry(resp.request_id)
      if entry and entry.callback then
        pcall(entry.callback, resp.subtype == 'success', resp)
      end
    end,
    on_exit = function()
      finish(nil, 'claude exited before responding')
    end,
  })
  local spawned, spawn_err = pcall(function() proc:spawn() end)
  if not spawned then
    finish(nil, tostring(spawn_err))
    return
  end
  proc:send_control_list_models(function(ok, resp)
    if not ok then
      finish(nil, tostring(resp and resp.error or 'request failed'))
      return
    end
    finish(M._from_claude(resp.response and resp.response.models))
  end)
  vim.defer_fn(function() finish(nil, 'timed out') end, FETCH_TIMEOUT_MS)
end

---@param done fun(entries: cc.ModelEntry[]?, err: string?)
local function fetch_codex(done)
  local inst = require('cc')._find_live_instance('codex')
  if inst and inst.provider and inst.provider.request then
    local finish = once(nil, done)
    -- vim.json encodes {} as a JSON array; ModelListParams must be an object.
    inst.provider:request('model/list', vim.empty_dict(), function(result, err)
      if err or type(result) ~= 'table' then
        finish(nil, tostring(err and err.message or 'no result'))
        return
      end
      finish(M._from_codex(result.data))
    end)
    vim.defer_fn(function() finish(nil, 'timed out') end, FETCH_TIMEOUT_MS)
    return
  end

  -- No live session: one-shot headless app-server, same shape as
  -- codex.list_history.
  local client = require('cc.providers.codex').attach({ headless = true })
  local finish = once(function() client:close() end, done)
  client.on_exit = function()
    finish(nil, 'codex app-server exited before responding')
  end
  client.on_ready = function()
    client:request('model/list', vim.empty_dict(), function(result, err)
      if err or type(result) ~= 'table' then
        finish(nil, tostring(err and err.message or 'no result'))
        return
      end
      finish(M._from_codex(result.data))
    end)
  end
  local spawned, spawn_err = pcall(function() client:spawn() end)
  if not spawned then
    finish(nil, tostring(spawn_err))
    return
  end
  vim.defer_fn(function() finish(nil, 'timed out') end, FETCH_TIMEOUT_MS)
end

local FETCHERS = { claude = fetch_claude, codex = fetch_codex }

--- Fetch the latest model catalogs and rewrite the cache. Asynchronous:
--- all subprocess I/O happens on libuv pipes and results land via
--- vim.schedule. A provider that fails keeps its previous cache entries.
---@param opts { providers: string[]? }?
---@param cb fun(results: table<string, cc.ModelEntry[]>, errors: table<string, string>)?
function M.update(opts, cb)
  opts = opts or {}
  if M._updating then
    vim.notify('cc.nvim: model update already in progress', vim.log.levels.WARN)
    return
  end
  local names = {}
  for _, name in ipairs(opts.providers or { 'claude', 'codex' }) do
    if not vim.tbl_contains(names, name) then table.insert(names, name) end
  end
  if #names == 0 then return end
  M._updating = true
  vim.notify('cc.nvim: updating models (' .. table.concat(names, ', ') .. ')…',
    vim.log.levels.INFO)

  local results, errors, finished = {}, {}, {}
  local remaining = #names
  local function finish_provider(name, entries, err)
    if finished[name] then return end
    finished[name] = true
    if entries then results[name] = entries else errors[name] = err or 'unknown error' end
    remaining = remaining - 1
    if remaining > 0 then return end
    M._updating = false

    local parts = {}
    if next(results) then
      local data = M.load() or {}
      data.version = data.version or 1
      data.providers = type(data.providers) == 'table' and data.providers or {}
      for name2, entries2 in pairs(results) do
        data.providers[name2] = entries2
      end
      data.updated_at = os.time()
      local wrote, werr = write_cache(data)
      if not wrote then
        vim.notify('cc.nvim: failed to write models cache: ' .. tostring(werr),
          vim.log.levels.ERROR)
      else
        for _, name2 in ipairs(names) do
          if results[name2] then
            table.insert(parts, name2 .. ' ' .. #results[name2])
          end
        end
      end
    end
    local message = #parts > 0
      and ('cc.nvim: models updated — ' .. table.concat(parts, ', '))
      or 'cc.nvim: model update failed'
    local level = vim.log.levels.INFO
    for _, name2 in ipairs(names) do
      if errors[name2] then
        message = message .. '; ' .. name2 .. ' failed: ' .. errors[name2]
        level = vim.log.levels.WARN
      end
    end
    vim.notify(message, level)
    if cb then cb(results, errors) end
  end

  for _, name in ipairs(names) do
    local fetch = FETCHERS[name]
    if not fetch then
      finish_provider(name, nil, 'unknown provider')
    else
      local ok, err = pcall(fetch, function(entries, ferr)
        finish_provider(name, entries, ferr)
      end)
      if not ok then finish_provider(name, nil, tostring(err)) end
    end
  end
end

return M
