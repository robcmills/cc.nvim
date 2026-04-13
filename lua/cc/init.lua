-- cc.nvim: Claude Code Neovim plugin.
-- Spawns the `claude` CLI and renders its NDJSON stream into buffers.

local Config = require('cc.config')
local Process = require('cc.process')
local Session = require('cc.session')
local Output = require('cc.output')
local Prompt = require('cc.prompt')
local Router = require('cc.router')

local M = {}

---@class cc.State
---@field session cc.Session?
---@field process cc.Process?
---@field output cc.Output?
---@field prompt cc.Prompt?
---@field router cc.Router?
---@field output_winid integer?
---@field prompt_winid integer?
---@field last_session_id string?
local state = {
  session = nil,
  process = nil,
  output = nil,
  prompt = nil,
  router = nil,
  output_winid = nil,
  prompt_winid = nil,
  last_session_id = nil,
}

--- Public: configure the plugin.
function M.setup(opts)
  Config.setup(opts)
end

--- Public: returns true if cc.nvim has an active session.
function M.is_open()
  return state.process ~= nil and state.process:is_alive()
end

--- Set up buffer-local keymaps for the prompt buffer.
local function setup_prompt_keymaps(bufnr)
  local keys = Config.options.keymaps
  vim.keymap.set('n', keys.submit, function() M.submit() end,
    { buffer = bufnr, silent = true, desc = 'cc.nvim: submit prompt' })
  vim.keymap.set({ 'n', 'i' }, keys.interrupt, function() M.stop() end,
    { buffer = bufnr, silent = true, desc = 'cc.nvim: interrupt' })
  vim.keymap.set('n', keys.clear_prompt, function()
    if state.prompt then state.prompt:clear() end
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: clear prompt' })
  vim.keymap.set('n', keys.goto_output, function()
    if state.output_winid and vim.api.nvim_win_is_valid(state.output_winid) then
      vim.api.nvim_set_current_win(state.output_winid)
    end
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: goto output' })
end

--- Set up buffer-local keymaps for the output buffer.
local function setup_output_keymaps(bufnr)
  local keys = Config.options.keymaps
  vim.keymap.set('n', keys.goto_prompt, function()
    if state.prompt_winid and vim.api.nvim_win_is_valid(state.prompt_winid) then
      vim.api.nvim_set_current_win(state.prompt_winid)
      vim.cmd('startinsert')
    end
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: goto prompt' })
end

--- Create the horizontal split layout: output on top, prompt on bottom.
local function create_layout()
  state.session = Session.new()
  state.output = Output.new(state.session)
  state.prompt = Prompt.new()

  local output_buf = state.output:ensure_buffer()
  local prompt_buf = state.prompt:ensure_buffer()

  -- Output fills current window.
  vim.api.nvim_set_current_buf(output_buf)
  state.output_winid = vim.api.nvim_get_current_win()
  state.output:set_window(state.output_winid)

  -- Prompt opens below.
  vim.cmd('belowright ' .. Config.options.prompt_height .. 'split')
  vim.api.nvim_set_current_buf(prompt_buf)
  state.prompt_winid = vim.api.nvim_get_current_win()
  state.prompt:set_window(state.prompt_winid)

  setup_prompt_keymaps(prompt_buf)
  setup_output_keymaps(output_buf)

  -- Start in insert mode in prompt buffer for immediate typing.
  vim.cmd('startinsert')
end

--- Public: open cc.nvim (spawn process, create buffers, set up layout).
---@param opts { permission_mode: string? }?
function M.open(opts)
  opts = opts or {}
  if M.is_open() then
    if state.prompt_winid and vim.api.nvim_win_is_valid(state.prompt_winid) then
      vim.api.nvim_set_current_win(state.prompt_winid)
    end
    return
  end

  create_layout()

  state.router = Router.new({
    session = state.session,
    output = state.output,
    on_session_id = function(id) state.last_session_id = id end,
  })

  state.process = Process.new({
    claude_cmd = Config.options.claude_cmd,
    cwd = vim.fn.getcwd(),
    session_id = nil,
    permission_mode = opts.permission_mode or Config.options.permission_mode,
    model = Config.options.model,
    extra_args = Config.options.extra_args,
    on_message = function(msg) state.router:dispatch(msg) end,
    on_stderr = function(data)
      vim.notify('cc.nvim [stderr]: ' .. data, vim.log.levels.WARN)
    end,
    on_exit = function(code, signal)
      if code ~= 0 then
        vim.notify('cc.nvim: claude exited with code ' .. code, vim.log.levels.WARN)
      end
      if state.output then
        state.output:render_notice('Session ended')
      end
    end,
  })

  state.router:set_process(state.process)

  local ok, err = pcall(function() state.process:spawn() end)
  if not ok then
    vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    state.process = nil
  end
end

--- Public: open in plan mode.
function M.plan()
  M.open({ permission_mode = 'plan' })
end

--- Public: resume a specific session by id.
---@param session_id string
function M.resume(session_id)
  if not session_id or session_id == '' then
    vim.notify('cc.nvim: resume requires a session id', vim.log.levels.WARN)
    return
  end
  if M.is_open() then
    M.close()
  end
  create_layout()

  -- Pre-render transcript so the UI shows past conversation.
  local history = require('cc.history')
  local entries = history.list_for_cwd()
  local path
  for _, e in ipairs(entries) do
    if e.session_id == session_id then path = e.path; break end
  end
  if not path then
    -- Also search globally (resume across projects).
    for _, e in ipairs(history.list_all()) do
      if e.session_id == session_id then path = e.path; break end
    end
  end

  if path then
    local config = Config.options
    local records = history.read_transcript(path)
    local max = config.history_max_records or 200
    local start_idx = 1
    if #records > max then
      start_idx = #records - max + 1
      state.output:render_notice(string.format(
        'earlier history hidden (%d records); showing last %d', start_idx - 1, max))
    end
    for i = start_idx, #records do
      state.output:render_historical_record(records[i])
    end
    state.output:render_notice('resumed ' .. session_id:sub(1, 8))
  else
    state.output:render_notice('resuming ' .. session_id:sub(1, 8) .. ' (no local transcript found)')
  end

  state.router = Router.new({
    session = state.session,
    output = state.output,
    on_session_id = function(id) state.last_session_id = id end,
  })
  state.process = Process.new({
    claude_cmd = Config.options.claude_cmd,
    cwd = vim.fn.getcwd(),
    session_id = session_id,
    permission_mode = Config.options.permission_mode,
    model = Config.options.model,
    extra_args = Config.options.extra_args,
    on_message = function(msg) state.router:dispatch(msg) end,
    on_stderr = function(data) vim.notify('cc.nvim [stderr]: ' .. data, vim.log.levels.WARN) end,
    on_exit = function(code)
      if code ~= 0 then
        vim.notify('cc.nvim: claude exited with code ' .. code, vim.log.levels.WARN)
      end
      if state.output then state.output:render_notice('Session ended') end
    end,
  })
  state.router:set_process(state.process)
  state.last_session_id = session_id
  local ok, err = pcall(function() state.process:spawn() end)
  if not ok then
    vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    state.process = nil
  end
end

--- Public: resume most recent session for the current cwd.
function M.continue_last()
  local entries = require('cc.history').list_for_cwd()
  if #entries == 0 then
    vim.notify('cc.nvim: no prior sessions for this cwd', vim.log.levels.INFO)
    return
  end
  M.resume(entries[1].session_id)
end

--- Public: pick a session to resume.
---@param all_projects boolean? if true, include sessions from other cwds
function M.history(all_projects)
  local history = require('cc.history')
  local entries = all_projects and history.list_all() or history.list_for_cwd()
  if #entries == 0 then
    vim.notify('cc.nvim: no sessions found', vim.log.levels.INFO)
    return
  end
  vim.ui.select(entries, {
    prompt = all_projects and 'Resume session (all projects):' or 'Resume session:',
    format_item = function(e) return history.format_entry(e, all_projects or false) end,
  }, function(choice)
    if choice then M.resume(choice.session_id) end
  end)
end

--- Public: open the last seen plan_file_path if any; falls back to picker.
function M.plan_show()
  if state.last_plan_file and state.last_plan_file ~= '' then
    vim.cmd('tabedit ' .. vim.fn.fnameescape(state.last_plan_file))
    return
  end
  -- Fallback: search ~/.claude/plans
  local plans_dir = vim.fn.expand('~/.claude/plans')
  if vim.fn.isdirectory(plans_dir) ~= 1 then
    vim.notify('cc.nvim: no plan file tracked and ~/.claude/plans does not exist', vim.log.levels.WARN)
    return
  end
  local plans = vim.fn.globpath(plans_dir, '*.md', false, true)
  if #plans == 0 then
    vim.notify('cc.nvim: no plan files found', vim.log.levels.INFO)
    return
  end
  vim.ui.select(plans, { prompt = 'Open plan: ' }, function(choice)
    if choice then vim.cmd('tabedit ' .. vim.fn.fnameescape(choice)) end
  end)
end

--- Called by the interactive handlers when we observe a plan_file_path.
---@param path string
function M._set_last_plan_file(path)
  state.last_plan_file = path
end

--- Public: submit current prompt buffer content to the agent.
function M.submit()
  if not M.is_open() then
    vim.notify('cc.nvim: not open. Run :CcOpen first.', vim.log.levels.WARN)
    return
  end
  if not state.prompt:has_content() then
    return
  end
  local text = state.prompt:read()
  state.prompt:clear()

  state.session:add_user_turn(text)
  state.output:render_user_turn(text)

  state.process:write({
    type = 'user',
    session_id = state.last_session_id or '',
    message = { role = 'user', content = text },
    parent_tool_use_id = vim.NIL,
  })
end

--- Public: send SIGINT to interrupt current generation.
function M.stop()
  if state.process then
    state.process:interrupt()
    if state.output then
      state.output:render_notice('Interrupted')
    end
  end
end

--- Public: close cc.nvim (kill process, close windows).
function M.close()
  if state.output then
    state.output:stop_spinner()
  end
  if state.process then
    state.process:close()
    state.process = nil
  end
  if state.output_winid and vim.api.nvim_win_is_valid(state.output_winid) then
    pcall(vim.api.nvim_win_close, state.output_winid, true)
  end
  if state.prompt_winid and vim.api.nvim_win_is_valid(state.prompt_winid) then
    pcall(vim.api.nvim_win_close, state.prompt_winid, true)
  end
  state.output_winid = nil
  state.prompt_winid = nil
  state.session = nil
  state.output = nil
  state.prompt = nil
  state.router = nil
end

--- Public: toggle visibility (close if open, else open).
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Public: set fold level on the output buffer's window.
---@param level integer 0..3
function M.set_fold_level(level)
  if state.output then
    state.output:set_fold_level(level)
  end
end

--- Internal: expose state for integration modules (cmp source, etc).
--- Stable surface: .session (cc.Session), .last_session_id.
M.__state = state

--- Public: slash commands available in the current session (for completion).
---@return string[]?
function M.get_slash_commands()
  if state.session then return state.session.slash_commands end
  return nil
end

return M
