-- Claude provider: the original cc.nvim transport (claude CLI stream-json)
-- behind the provider interface. Process spawning, NDJSON routing, and the
-- claude-specific control_request plumbing live here (via cc.process and
-- cc.router); shared UI code talks only to the interface documented in
-- cc.providers.

local Config = require('cc.config')
local Process = require('cc.process')
local Router = require('cc.router')

local M = {}

M.name = 'claude'

---@type cc.ProviderCapabilities
M.capabilities = {
  permission_modes = true,
  effort = true,
  cost_usd = true,
  slash_commands = true,
  auto_rename = true,
  local_history = true,
  plan_mode = true,
}

--- Effective claude options. providers.claude.* wins when set; the legacy
--- top-level keys (claude_cmd, permission_mode, model, extra_args) fill gaps
--- so existing configs keep working unchanged.
---@return { cmd: string, permission_mode: string?, model: string?, extra_args: string[] }
function M.options()
  local o = Config.options
  local p = (o.providers or {}).claude or {}
  return {
    cmd = p.cmd or o.claude_cmd or 'claude',
    permission_mode = p.permission_mode or o.permission_mode,
    model = p.model or o.model,
    extra_args = p.extra_args or o.extra_args or {},
  }
end

---@class cc.ClaudeProvider
---@field name string
---@field capabilities cc.ProviderCapabilities
---@field process cc.Process
---@field router cc.Router
---@field instance cc.Instance?
---@field session cc.Session
---@field output cc.Output
---@field resume_id string?
local Claude = {}
Claude.__index = Claude

---@class cc.ProviderCtx
---@field instance cc.Instance?
---@field session cc.Session
---@field output cc.Output
---@field resume_id string? session/thread id to resume
---@field permission_mode string? explicit permission mode (Claude-only)
---@field on_session_id fun(id: string)?
---@field on_exit fun(code: integer, signal: integer)?

--- Build a Claude provider instance wired to one cc.Instance.
---@param ctx cc.ProviderCtx
---@return cc.ClaudeProvider
function M.attach(ctx)
  local opts = M.options()
  local self = setmetatable({
    name = M.name,
    capabilities = M.capabilities,
    instance = ctx.instance,
    session = ctx.session,
    output = ctx.output,
    resume_id = ctx.resume_id,
  }, Claude)

  -- Seed the session's permission_mode so the statusline reflects the
  -- effective mode immediately, before the CLI's init message arrives.
  -- Only for fresh sessions with an explicit value — resume seeds from the
  -- transcript in prerender_resume, and when nothing specifies a mode we
  -- wait for get_settings/init rather than guess wrong.
  local effective_mode = ctx.permission_mode or opts.permission_mode
  if not ctx.resume_id and ctx.session then
    ctx.session.permission_mode = effective_mode
  end

  self.router = Router.new({
    session = ctx.session,
    output = ctx.output,
    instance = ctx.instance,
    on_session_id = ctx.on_session_id,
  })

  self.process = Process.new({
    claude_cmd = opts.cmd,
    cwd = vim.fn.getcwd(),
    session_id = ctx.resume_id,
    permission_mode = effective_mode,
    model = opts.model,
    extra_args = opts.extra_args,
    on_message = function(msg) self.router:dispatch(msg) end,
    on_stderr = function(data)
      vim.notify('cc.nvim [stderr]: ' .. data, vim.log.levels.WARN)
    end,
    on_exit = ctx.on_exit,
  })
  self.router:set_process(self.process)

  return self
end

function Claude:spawn()
  self.process:spawn()
  -- No explicit mode from opts/Config on a fresh session — ask the CLI for
  -- its effective settings so the statusline can show the resolved
  -- defaultMode before the first prompt triggers an init message.
  if not self.resume_id and self.session and not self.session.permission_mode then
    self.process:send_control_get_settings()
  end
end

function Claude:is_alive()
  return self.process ~= nil and self.process:is_alive()
end

function Claude:close()
  if self.process then self.process:close() end
end

---@param text string
function Claude:send(text)
  self.process:write({
    type = 'user',
    session_id = (self.instance and self.instance.last_session_id) or '',
    message = { role = 'user', content = text },
    parent_tool_use_id = vim.NIL,
  })
end

--- Request turn interruption via control_request. Returns the request_id
--- when sent, nil when the process is not alive.
---@return string?
function Claude:interrupt()
  return self.process:send_control_interrupt()
end

---@param mode string
---@return string? request_id
function Claude:set_permission_mode(mode)
  return self.process:send_control_set_permission_mode(mode)
end

function Claude:start_dump(path) return self.process:start_dump(path) end
function Claude:stop_dump() return self.process:stop_dump() end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

--- List sessions. Callback-style for parity with providers whose history
--- requires a subprocess round-trip; Claude reads local JSONL synchronously.
---@param opts { all: boolean?, cwd: string? }?
---@param cb fun(entries: cc.HistoryEntry[])
function M.list_history(opts, cb)
  opts = opts or {}
  local history = require('cc.history')
  local entries = opts.all and history.list_all() or history.list_for_cwd(opts.cwd)
  cb(entries)
end

---@param entry cc.HistoryEntry
---@param show_cwd boolean
---@return string
function M.format_history_entry(entry, show_cwd)
  return require('cc.history').format_entry(entry, show_cwd)
end

--- Pre-render a resumed session's transcript from the local JSONL so the UI
--- shows the past conversation before the subprocess connects. Also seeds
--- session usage/model/permission_mode from the transcript metadata.
---@param inst cc.Instance
---@param session_id string
function M.prerender_resume(inst, session_id)
  local history = require('cc.history')
  local config = Config.options
  local entries = history.list_for_cwd()
  local path
  for _, e in ipairs(entries) do
    if e.session_id == session_id then path = e.path; break end
  end
  if not path then
    for _, e in ipairs(history.list_all()) do
      if e.session_id == session_id then path = e.path; break end
    end
  end

  if not path then
    inst.output:render_notice('resuming ' .. session_id:sub(1, 8) .. ' (no local transcript found)')
    inst.session.permission_mode = M.options().permission_mode
    return
  end

  local meta = history.read_session_meta(path)
  inst.session.input_tokens = meta.input_tokens
  inst.session.output_tokens = meta.output_tokens
  inst.session.cache_creation_input_tokens = meta.cache_creation_input_tokens
  inst.session.cache_read_input_tokens = meta.cache_read_input_tokens
  inst.session.context_tokens = meta.context_tokens
  inst.session.cost_usd = meta.cost_usd
  inst.session.model = meta.model or inst.session.model
  inst.session.permission_mode =
    meta.permission_mode or M.options().permission_mode or inst.session.permission_mode
  inst.session_name = meta.custom_title or meta.ai_title or inst.session_name
  if inst.session_name and inst.session_name ~= '' then
    require('cc')._apply_session_buf_names(inst, inst.session_name)
  end
  local records = history.read_transcript(path)
  local max = config.history_max_records or 200
  local start_idx = 1
  if #records > max then
    start_idx = #records - max + 1
    inst.output:render_notice(string.format(
      'earlier history hidden (%d records); showing last %d', start_idx - 1, max))
  end
  for i = start_idx, #records do
    inst.output:render_historical_record(records[i])
  end
  inst.output:render_notice('resumed ' .. session_id:sub(1, 8))
  require('cc.statusline').refresh(inst)
end

M.Claude = Claude
return M
