-- Cached async git info (branch, PR number) for the plugin's cwd.
-- Never blocks the render path; callers read whatever is currently cached.

local uv = vim.uv or vim.loop

local M = {}

local CACHE_TTL_MS = 30 * 1000

---@class cc.GitCache
---@field branch string?
---@field pr string?
---@field branch_fetched_at integer
---@field pr_fetched_at integer
---@field branch_inflight boolean
---@field pr_inflight boolean
---@field cwd string
local cache = {
  branch = nil,
  pr = nil,
  branch_fetched_at = 0,
  pr_fetched_at = 0,
  branch_inflight = false,
  pr_inflight = false,
  cwd = '',
}

local function now_ms()
  return uv.now()
end

local function current_cwd()
  return vim.fn.getcwd()
end

--- Reset cache when cwd changes so stale branch/PR don't leak across repos.
local function maybe_reset_for_cwd()
  local cwd = current_cwd()
  if cwd ~= cache.cwd then
    cache.cwd = cwd
    cache.branch = nil
    cache.pr = nil
    cache.branch_fetched_at = 0
    cache.pr_fetched_at = 0
  end
end

---@param on_done function? invoked after fetch resolves (for refresh triggers)
local function fetch_branch(on_done)
  if cache.branch_inflight then return end
  cache.branch_inflight = true
  local cwd = cache.cwd
  vim.system(
    { 'git', '-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD' },
    { text = true },
    vim.schedule_wrap(function(res)
      cache.branch_inflight = false
      cache.branch_fetched_at = now_ms()
      if res and res.code == 0 and res.stdout then
        local branch = res.stdout:gsub('%s+$', '')
        if branch == '' or branch == 'HEAD' then
          cache.branch = nil
        else
          cache.branch = branch
        end
      else
        cache.branch = nil
      end
      if on_done then pcall(on_done) end
    end)
  )
end

---@param on_done function?
local function fetch_pr(on_done)
  if cache.pr_inflight then return end
  if vim.fn.executable('gh') ~= 1 then
    cache.pr = nil
    cache.pr_fetched_at = now_ms()
    return
  end
  cache.pr_inflight = true
  local cwd = cache.cwd
  vim.system(
    { 'gh', 'pr', 'view', '--json', 'number', '-q', '.number' },
    { text = true, cwd = cwd },
    vim.schedule_wrap(function(res)
      cache.pr_inflight = false
      cache.pr_fetched_at = now_ms()
      if res and res.code == 0 and res.stdout then
        local num = res.stdout:gsub('%s+$', '')
        if num ~= '' and num:match('^%d+$') then
          cache.pr = '#' .. num
        else
          cache.pr = nil
        end
      else
        cache.pr = nil
      end
      if on_done then pcall(on_done) end
    end)
  )
end

--- Read cached branch; kick off background fetch if stale.
---@param on_update function? called when a background fetch changes the value
---@return string?
function M.branch(on_update)
  maybe_reset_for_cwd()
  if now_ms() - cache.branch_fetched_at > CACHE_TTL_MS then
    fetch_branch(on_update)
  end
  return cache.branch
end

---@param on_update function?
---@return string?
function M.pr(on_update)
  maybe_reset_for_cwd()
  if now_ms() - cache.pr_fetched_at > CACHE_TTL_MS then
    fetch_pr(on_update)
  end
  return cache.pr
end

--- Force-invalidate the cache (tests, manual refresh).
function M.invalidate()
  cache.branch = nil
  cache.pr = nil
  cache.branch_fetched_at = 0
  cache.pr_fetched_at = 0
end

return M
