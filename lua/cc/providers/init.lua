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

return M
