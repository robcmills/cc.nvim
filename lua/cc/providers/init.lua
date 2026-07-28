-- Provider registry: resolves the configured provider module.
--
-- A provider module exposes:
--   M.name                 'claude' | 'codex'
--   M.capabilities         table of feature flags (see cc.ProviderCapabilities)
--   M.attach(ctx)          build a provider instance wired to one cc.Instance
--   M.list_history(opts, cb)         async session listing for the picker
--   M.format_history_entry(e, cwd?)  one picker line for an entry
--   M.prerender_resume(inst, id)     optional: pre-render transcript before spawn
--   M.health(h)            optional: provider-specific :checkhealth section
--
-- A provider *instance* (returned by attach) exposes:
--   :spawn()               start the subprocess (may error)
--   :is_alive()            boolean
--   :close()               terminate the subprocess
--   :send(text)            submit a user prompt
--   :interrupt()           request turn interruption; truthy when sent
--   :set_model(model, cb?)  select the model for subsequent turns
--   :set_effort(level, cb?) select reasoning effort for subsequent turns
--   :set_permission_mode(mode)  Claude-only (gate on capabilities)
--   :rename(name, cb?)     optional: provider-native session rename
--   :auto_rename_spec(prompt, cfg)  optional: one-shot title command
--   :start_dump(path) / :stop_dump()  tee raw wire bytes for fixture capture
--   .name, .capabilities   mirrors of the module fields
--   .process               underlying transport when distinct from the instance

local M = {}

---@class cc.ProviderCapabilities
---@field permission_modes boolean Claude permission modes (--permission-mode, Shift+Tab cycle)
---@field effort boolean reasoning-effort control (/effort)
---@field cost_usd boolean provider reports USD cost per turn
---@field slash_commands boolean provider advertises slash commands / skills
---@field auto_rename boolean first-prompt auto-title via a provider command
---@field local_history boolean history read from local files without a subprocess
---@field plan_mode boolean Claude plan mode (:CcPlan)

local MODULES = {
  claude = 'cc.providers.claude',
  codex = 'cc.providers.codex',
}

local NAMES = { 'claude', 'codex' }

local CLAUDE_ALIASES = {
  fable = true,
  haiku = true,
  opus = true,
  sonnet = true,
}

--- Infer a provider from a model name. Returns nil for unknown/ambiguous
--- names so callers can preserve the configured provider as the fallback.
---@param model any
---@return 'claude'|'codex'|nil
function M.infer_from_model(model)
  if type(model) ~= 'string' then return nil end
  local normalized = model:match('^%s*(.-)%s*$'):lower()
  if normalized == '' then return nil end
  local alias = normalized:gsub('%[.-%]$', '')

  if CLAUDE_ALIASES[alias]
      or normalized:match('^claude%-')
      or normalized:match('^anthropic/claude%-') then
    return 'claude'
  end
  if normalized:match('^gpt%-')
      or normalized:match('^o%d')
      or normalized == 'codex'
      or normalized:match('^codex%-')
      or normalized:match('^openai/') then
    return 'codex'
  end
  return nil
end

--- Name of the configured provider ('claude' when unset).
---@return string
function M.current_name()
  return require('cc.config').options.provider or 'claude'
end

--- Resolve a provider module by name.
---@param name string
---@return table? provider, string? err
function M.get(name)
  local modname = MODULES[name]
  if not modname then
    return nil, ('unknown provider %q (expected one of: claude, codex)'):format(tostring(name))
  end
  local ok, mod = pcall(require, modname)
  if not ok then
    return nil, ('failed to load provider %q: %s'):format(name, tostring(mod))
  end
  return mod
end

--- Resolve the configured provider module.
---@return table? provider, string? err
function M.current()
  return M.get(M.current_name())
end

--- List history from every provider, or only `opts.provider` when supplied.
--- Provider callbacks may be synchronous (Claude) or asynchronous (Codex);
--- the aggregate callback fires once all requested providers have replied.
--- Every returned entry is tagged with the provider needed to resume it.
---@param opts { all: boolean?, cwd: string?, limit: integer?, provider: string? }?
---@param cb fun(entries: cc.HistoryEntry[])
function M.list_history(opts, cb)
  opts = opts or {}
  local names = opts.provider and { opts.provider } or NAMES
  local entries = {}
  local remaining = #names

  local function finish_provider()
    remaining = remaining - 1
    if remaining > 0 then return end
    table.sort(entries, function(a, b)
      local a_mtime = tonumber(a.mtime) or 0
      local b_mtime = tonumber(b.mtime) or 0
      if a_mtime ~= b_mtime then return a_mtime > b_mtime end
      return tostring(a.provider) < tostring(b.provider)
    end)
    cb(entries)
  end

  for _, name in ipairs(names) do
    local P, err = M.get(name)
    if not P then
      vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
      finish_provider()
    else
      local called = false
      local ok, list_err = pcall(P.list_history, opts, function(provider_entries)
        if called then return end
        called = true
        for _, entry in ipairs(provider_entries or {}) do
          local tagged = vim.tbl_extend('force', {}, entry)
          tagged.provider = name
          table.insert(entries, tagged)
        end
        finish_provider()
      end)
      if not ok and not called then
        called = true
        vim.notify('cc.nvim: failed to list ' .. name .. ' sessions: '
          .. tostring(list_err), vim.log.levels.ERROR)
        finish_provider()
      end
    end
  end
end

return M
