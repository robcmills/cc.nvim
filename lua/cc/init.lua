-- cc.nvim: Claude Code Neovim plugin.
-- Spawns the `claude` CLI and renders its NDJSON stream into buffers.
-- Supports multiple simultaneous sessions, each with its own buffers.

local Config = require('cc.config')
local Process = require('cc.process')
local Session = require('cc.session')
local Output = require('cc.output')
local Prompt = require('cc.prompt')
local Router = require('cc.router')

local M = {}

-- ---------------------------------------------------------------------------
-- Instance management
-- ---------------------------------------------------------------------------

---@class cc.Instance
---@field session cc.Session?
---@field process cc.Process?
---@field output cc.Output?
---@field prompt cc.Prompt?
---@field router cc.Router?
---@field output_winid integer?
---@field prompt_winid integer?
---@field last_session_id string?
---@field last_plan_file string?
---@field session_name string? user-set session title (set via /rename)
---@field remote_control_active boolean?

local instances = {} -- keyed by prompt bufnr
local next_instance_id = 1

--- Find the instance that owns the given buffer (prompt or output).
---@param bufnr integer
---@return cc.Instance?
local function find_instance(bufnr)
  if instances[bufnr] then return instances[bufnr] end
  for _, inst in pairs(instances) do
    if inst.output and inst.output.bufnr == bufnr then return inst end
  end
  return nil
end

--- Find the instance for the currently active buffer.
---@return cc.Instance?
local function get_current_instance()
  return find_instance(vim.api.nvim_get_current_buf())
end

--- Public: find instance by buffer number (for integrations like cmp_source).
M.find_instance = find_instance

-- ---------------------------------------------------------------------------
-- Public: configure the plugin.
-- ---------------------------------------------------------------------------
function M.setup(opts)
  Config.setup(opts)
end

-- ---------------------------------------------------------------------------
-- Buffer-local keymaps (scoped per-instance via closure)
-- ---------------------------------------------------------------------------

local function setup_prompt_keymaps(inst)
  local bufnr = inst.prompt.bufnr
  local keys = Config.options.keymaps
  vim.keymap.set('n', keys.submit, function() M.submit() end,
    { buffer = bufnr, silent = true, desc = 'cc.nvim: submit prompt' })
  vim.keymap.set({ 'n', 'i' }, keys.interrupt, function() M.stop() end,
    { buffer = bufnr, silent = true, desc = 'cc.nvim: interrupt' })
  vim.keymap.set('n', keys.clear_prompt, function()
    inst.prompt:clear()
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: clear prompt' })
  vim.keymap.set('n', keys.goto_output, function()
    if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid) then
      vim.api.nvim_set_current_win(inst.output_winid)
    end
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: goto output' })
end

local function setup_output_keymaps(inst)
  local bufnr = inst.output.bufnr
  local keys = Config.options.keymaps
  vim.keymap.set('n', keys.goto_prompt, function()
    if inst.prompt_winid and vim.api.nvim_win_is_valid(inst.prompt_winid) then
      vim.api.nvim_set_current_win(inst.prompt_winid)
      vim.cmd('startinsert')
    end
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: goto prompt' })
end

-- ---------------------------------------------------------------------------
-- Buffer sidebar integration autocmds (scoped per-instance)
-- ---------------------------------------------------------------------------

local function setup_buffer_autocmds(inst)
  local output_bufnr = inst.output.bufnr
  local prompt_bufnr = inst.prompt.bufnr
  local group = vim.api.nvim_create_augroup('cc.buffer_integration.' .. prompt_bufnr, { clear = true })

  -- When prompt leaves a window, close the output companion (unless moving to output).
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = prompt_bufnr,
    callback = function()
      vim.schedule(function()
        local cur_buf = vim.api.nvim_get_current_buf()
        if cur_buf == output_bufnr then return end
        if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid) then
          if vim.api.nvim_win_get_buf(inst.output_winid) == output_bufnr then
            vim.api.nvim_win_close(inst.output_winid, true)
          end
        end
        inst.output_winid = nil
        inst.prompt_winid = nil
      end)
    end,
  })

  -- When output leaves a window, close the prompt companion (unless moving to prompt).
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = output_bufnr,
    callback = function()
      vim.schedule(function()
        local cur_buf = vim.api.nvim_get_current_buf()
        if cur_buf == prompt_bufnr then return end
        if inst.prompt_winid and vim.api.nvim_win_is_valid(inst.prompt_winid) then
          if vim.api.nvim_win_get_buf(inst.prompt_winid) == prompt_bufnr then
            vim.api.nvim_win_close(inst.prompt_winid, true)
          end
        end
        inst.output_winid = nil
        inst.prompt_winid = nil
      end)
    end,
  })

  -- When prompt enters a window, recreate the output companion above.
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = prompt_bufnr,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(output_bufnr) then return end
        if not inst.process or not inst.process:is_alive() then return end
        if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid) then
          return
        end
        local prompt_win = nil
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(win) == prompt_bufnr then
            prompt_win = win
            break
          end
        end
        if not prompt_win then return end
        inst.prompt_winid = prompt_win
        vim.api.nvim_set_current_win(prompt_win)
        vim.cmd('aboveleft split')
        vim.api.nvim_set_current_buf(output_bufnr)
        inst.output_winid = vim.api.nvim_get_current_win()
        inst.output:set_window(inst.output_winid)
        require('cc.statusline').attach(inst, inst.output_winid)
        vim.api.nvim_set_current_win(prompt_win)
        vim.api.nvim_win_set_height(prompt_win, Config.options.prompt_height)
        -- New windows on an existing buffer start with cursor at line 1,
        -- which would show the top of a long transcript. Anchor to the
        -- last line so returning to the session shows the most recent
        -- output. Schedule so the fix runs after layout settles (split
        -- + resize + BufWinEnter autocmds all complete first).
        local output_winid = inst.output_winid
        vim.schedule(function()
          if not output_winid or not vim.api.nvim_win_is_valid(output_winid) then return end
          if vim.api.nvim_win_get_buf(output_winid) ~= output_bufnr then return end
          pcall(vim.api.nvim_win_call, output_winid, function()
            local last = vim.api.nvim_buf_line_count(output_bufnr)
            vim.api.nvim_win_set_cursor(output_winid, { last, 0 })
            vim.cmd('normal! zb')
          end)
        end)
      end)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Instance creation + teardown
-- ---------------------------------------------------------------------------

--- Create a new instance with layout: output above (companion), prompt below (primary).
---@param opts { reuse_prompt_winid: integer?, reuse_output_winid: integer? }?
---@return cc.Instance
local function create_instance(opts)
  opts = opts or {}
  local id = next_instance_id
  next_instance_id = next_instance_id + 1

  local prompt_name = id == 1 and 'cc-nvim' or ('cc-nvim-' .. id)
  local output_name = id == 1 and 'cc-output' or ('cc-output-' .. id)

  local inst = {
    session = Session.new(),
    process = nil,
    output = nil,
    prompt = nil,
    router = nil,
    output_winid = nil,
    prompt_winid = nil,
    last_session_id = nil,
    last_plan_file = nil,
    session_name = nil,
  }

  inst.output = Output.new(inst.session, output_name)
  inst.prompt = Prompt.new(prompt_name)

  local output_buf = inst.output:ensure_buffer()
  local prompt_buf = inst.prompt:ensure_buffer()

  local reuse_prompt = opts.reuse_prompt_winid
  local reuse_output = opts.reuse_output_winid
  if reuse_prompt and not vim.api.nvim_win_is_valid(reuse_prompt) then reuse_prompt = nil end
  if reuse_output and not vim.api.nvim_win_is_valid(reuse_output) then reuse_output = nil end

  if reuse_prompt and reuse_output then
    -- Reuse existing windows: swap new buffers into place.
    vim.api.nvim_win_set_buf(reuse_prompt, prompt_buf)
    inst.prompt_winid = reuse_prompt
    inst.prompt:set_window(reuse_prompt)

    vim.api.nvim_win_set_buf(reuse_output, output_buf)
    inst.output_winid = reuse_output
    inst.output:set_window(reuse_output)

    vim.api.nvim_set_current_win(reuse_prompt)
    vim.api.nvim_win_set_height(reuse_prompt, Config.options.prompt_height)
  else
    -- Prompt is the primary buffer — it fills current window.
    vim.api.nvim_set_current_buf(prompt_buf)
    inst.prompt_winid = vim.api.nvim_get_current_win()
    inst.prompt:set_window(inst.prompt_winid)

    -- Output opens above as a companion.
    vim.cmd('aboveleft split')
    vim.api.nvim_set_current_buf(output_buf)
    inst.output_winid = vim.api.nvim_get_current_win()
    inst.output:set_window(inst.output_winid)

    -- Return focus to prompt and resize it.
    vim.api.nvim_set_current_win(inst.prompt_winid)
    vim.api.nvim_win_set_height(inst.prompt_winid, Config.options.prompt_height)
  end

  setup_prompt_keymaps(inst)
  setup_output_keymaps(inst)

  -- Set up autocmds after layout to avoid double-trigger from initial BufWinEnter.
  setup_buffer_autocmds(inst)

  -- Register in instances table.
  instances[prompt_buf] = inst

  -- Attach cc statusline to the output window so it renders at the output's
  -- own bottom edge. Requires laststatus=2 (set by attach).
  if inst.output_winid then
    require('cc.statusline').attach(inst, inst.output_winid)
  end

  -- Start in insert mode in prompt buffer for immediate typing.
  vim.cmd('startinsert')

  -- When opening a new instance while the user was focused in a prior
  -- instance's prompt window, that prompt's BufWinLeave autocmd schedules
  -- closing the old output window. With equalalways on (default), that
  -- close redistributes space and clobbers our prompt_height, and can
  -- leave the new output window's topline in a state where the last
  -- line shows at the top. Schedule a fixup that runs AFTER the pending
  -- close so our layout wins.
  local prompt_winid = inst.prompt_winid
  local output_winid = inst.output_winid
  local output_bufnr = inst.output.bufnr
  vim.schedule(function()
    if prompt_winid and vim.api.nvim_win_is_valid(prompt_winid) then
      pcall(vim.api.nvim_win_set_height, prompt_winid, Config.options.prompt_height)
    end
    if output_winid and vim.api.nvim_win_is_valid(output_winid)
        and vim.api.nvim_win_get_buf(output_winid) == output_bufnr then
      pcall(vim.api.nvim_win_call, output_winid, function()
        local last = vim.api.nvim_buf_line_count(output_bufnr)
        pcall(vim.api.nvim_win_set_cursor, output_winid, { last, 0 })
        pcall(vim.cmd, 'normal! zb')
      end)
    end
  end)

  return inst
end

--- Tear down an instance's process and buffer state, but leave its windows open
--- so a replacement instance can swap its new buffers into the same layout.
---@param inst cc.Instance
local function teardown_instance_keep_windows(inst)
  require('cc.statusline_spinner').stop(inst)
  if inst.process then
    inst.process:close()
    inst.process = nil
  end
  if inst.prompt and inst.prompt.bufnr > 0 then
    pcall(vim.api.nvim_del_augroup_by_name, 'cc.buffer_integration.' .. inst.prompt.bufnr)
  end
  if inst.prompt and inst.prompt.bufnr > 0 then
    if vim.api.nvim_buf_is_valid(inst.prompt.bufnr) then
      vim.bo[inst.prompt.bufnr].buflisted = false
    end
    instances[inst.prompt.bufnr] = nil
  end
  if inst.output and inst.output.bufnr and vim.api.nvim_buf_is_valid(inst.output.bufnr) then
    vim.bo[inst.output.bufnr].buflisted = false
  end
end

--- Tear down an instance: kill process, close windows, unlist buffer, remove from table.
---@param inst cc.Instance
local function close_instance(inst)
  require('cc.statusline_spinner').stop(inst)
  if inst.process then
    inst.process:close()
    inst.process = nil
  end
  -- Clear per-instance autocmds before closing windows to avoid cascading.
  if inst.prompt and inst.prompt.bufnr > 0 then
    pcall(vim.api.nvim_del_augroup_by_name, 'cc.buffer_integration.' .. inst.prompt.bufnr)
  end
  if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid) then
    pcall(vim.api.nvim_win_close, inst.output_winid, true)
  end
  if inst.prompt_winid and vim.api.nvim_win_is_valid(inst.prompt_winid) then
    pcall(vim.api.nvim_win_close, inst.prompt_winid, true)
  end
  -- Unlist buffers so they disappear from the sidebar; always remove from instances table.
  if inst.prompt and inst.prompt.bufnr > 0 then
    if vim.api.nvim_buf_is_valid(inst.prompt.bufnr) then
      vim.bo[inst.prompt.bufnr].buflisted = false
    end
    instances[inst.prompt.bufnr] = nil
  end
  if inst.output and inst.output.bufnr and vim.api.nvim_buf_is_valid(inst.output.bufnr) then
    vim.bo[inst.output.bufnr].buflisted = false
  end
  inst.output_winid = nil
  inst.prompt_winid = nil
  inst.session = nil
  inst.output = nil
  inst.prompt = nil
  inst.router = nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Public: returns true if the current buffer belongs to an active session.
function M.is_open()
  local inst = get_current_instance()
  return inst ~= nil and inst.process ~= nil and inst.process:is_alive()
end

--- Public: open a new cc.nvim session.
---@param opts { permission_mode: string? }?
function M.open(opts)
  opts = opts or {}

  local inst = create_instance()

  inst.router = Router.new({
    session = inst.session,
    output = inst.output,
    instance = inst,
    on_session_id = function(id)
      inst.last_session_id = id
      require('cc.statusline').refresh(inst)
    end,
  })

  inst.process = Process.new({
    claude_cmd = Config.options.claude_cmd,
    cwd = vim.fn.getcwd(),
    session_id = nil,
    permission_mode = opts.permission_mode or Config.options.permission_mode,
    model = Config.options.model,
    extra_args = Config.options.extra_args,
    on_message = function(msg) inst.router:dispatch(msg) end,
    on_stderr = function(data)
      vim.notify('cc.nvim [stderr]: ' .. data, vim.log.levels.WARN)
    end,
    on_exit = function(code, signal)
      if code ~= 0 then
        vim.notify('cc.nvim: claude exited with code ' .. code, vim.log.levels.WARN)
      end
      if inst.output then
        inst.output:render_notice('Session ended')
      end
      if inst.session then
        inst.session.is_streaming = false
        inst.session.turn_active = false
      end
      require('cc.statusline_spinner').stop(inst)
      require('cc.statusline').refresh(inst)
    end,
  })

  inst.router:set_process(inst.process)

  local ok, err = pcall(function() inst.process:spawn() end)
  if not ok then
    vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    inst.process = nil
  end
end

--- Public: open in plan mode.
function M.plan()
  M.open({ permission_mode = 'plan' })
end

--- Public: start a fresh session inside the current windows.
--- Equivalent to :CcClose + :CcNew but preserves the existing window layout.
function M.new_session()
  local inst = get_current_instance()
  if not inst then
    M.open()
    return
  end

  local prompt_winid = inst.prompt_winid
  local output_winid = inst.output_winid

  teardown_instance_keep_windows(inst)

  local new_inst = create_instance({
    reuse_prompt_winid = prompt_winid,
    reuse_output_winid = output_winid,
  })

  new_inst.router = Router.new({
    session = new_inst.session,
    output = new_inst.output,
    instance = new_inst,
    on_session_id = function(id)
      new_inst.last_session_id = id
      require('cc.statusline').refresh(new_inst)
    end,
  })

  new_inst.process = Process.new({
    claude_cmd = Config.options.claude_cmd,
    cwd = vim.fn.getcwd(),
    session_id = nil,
    permission_mode = Config.options.permission_mode,
    model = Config.options.model,
    extra_args = Config.options.extra_args,
    on_message = function(msg) new_inst.router:dispatch(msg) end,
    on_stderr = function(data)
      vim.notify('cc.nvim [stderr]: ' .. data, vim.log.levels.WARN)
    end,
    on_exit = function(code)
      if code ~= 0 then
        vim.notify('cc.nvim: claude exited with code ' .. code, vim.log.levels.WARN)
      end
      if new_inst.output then
        new_inst.output:render_notice('Session ended')
      end
      if new_inst.session then
        new_inst.session.is_streaming = false
        new_inst.session.turn_active = false
      end
      require('cc.statusline_spinner').stop(new_inst)
      require('cc.statusline').refresh(new_inst)
    end,
  })

  new_inst.router:set_process(new_inst.process)

  local ok, err = pcall(function() new_inst.process:spawn() end)
  if not ok then
    vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    new_inst.process = nil
  end
end

--- Public: resume a specific session by id.
---@param session_id string
function M.resume(session_id)
  if not session_id or session_id == '' then
    vim.notify('cc.nvim: resume requires a session id', vim.log.levels.WARN)
    return
  end

  local inst = create_instance()

  -- Pre-render transcript so the UI shows past conversation.
  local history = require('cc.history')
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

  if path then
    local config = Config.options
    local meta = history.read_session_meta(path)
    inst.session.input_tokens = meta.input_tokens
    inst.session.output_tokens = meta.output_tokens
    inst.session.cost_usd = meta.cost_usd
    inst.session.model = meta.model or inst.session.model
    inst.session.permission_mode =
      meta.permission_mode or config.permission_mode or inst.session.permission_mode
    inst.session_name = meta.custom_title or meta.ai_title or inst.session_name
    if inst.session_name and inst.session_name ~= '' then
      M._apply_session_buf_names(inst, inst.session_name)
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
  else
    inst.output:render_notice('resuming ' .. session_id:sub(1, 8) .. ' (no local transcript found)')
  end

  inst.router = Router.new({
    session = inst.session,
    output = inst.output,
    instance = inst,
    on_session_id = function(id)
      inst.last_session_id = id
      require('cc.statusline').refresh(inst)
    end,
  })
  inst.process = Process.new({
    claude_cmd = Config.options.claude_cmd,
    cwd = vim.fn.getcwd(),
    session_id = session_id,
    permission_mode = Config.options.permission_mode,
    model = Config.options.model,
    extra_args = Config.options.extra_args,
    on_message = function(msg) inst.router:dispatch(msg) end,
    on_stderr = function(data) vim.notify('cc.nvim [stderr]: ' .. data, vim.log.levels.WARN) end,
    on_exit = function(code)
      if code ~= 0 then
        vim.notify('cc.nvim: claude exited with code ' .. code, vim.log.levels.WARN)
      end
      if inst.output then inst.output:render_notice('Session ended') end
      if inst.session then
        inst.session.is_streaming = false
        inst.session.turn_active = false
      end
      require('cc.statusline_spinner').stop(inst)
      require('cc.statusline').refresh(inst)
    end,
  })
  inst.router:set_process(inst.process)
  inst.last_session_id = session_id
  local ok, err = pcall(function() inst.process:spawn() end)
  if not ok then
    vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    inst.process = nil
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
  local inst = get_current_instance()
  if inst and inst.last_plan_file and inst.last_plan_file ~= '' then
    vim.cmd('tabedit ' .. vim.fn.fnameescape(inst.last_plan_file))
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
---@param output_bufnr integer? buffer number to identify the instance
function M._set_last_plan_file(path, output_bufnr)
  if output_bufnr then
    local inst = find_instance(output_bufnr)
    if inst then inst.last_plan_file = path; return end
  end
  -- Fallback: set on any active instance (backwards compat).
  for _, inst in pairs(instances) do
    inst.last_plan_file = path
    return
  end
end

--- Public: submit current prompt buffer content to the agent.
function M.submit()
  local inst = get_current_instance()
  if not inst or not inst.process or not inst.process:is_alive() then
    vim.notify('cc.nvim: not open. Run :CcNew first.', vim.log.levels.WARN)
    return
  end
  if not inst.prompt:has_content() then
    return
  end
  if inst.session.turn_active or inst.session.is_streaming then
    vim.notify(
      'cc.nvim: agent turn in progress — wait for it to finish or interrupt first',
      vim.log.levels.WARN)
    return
  end
  local text = inst.prompt:read()

  -- Intercept client-side slash commands before forwarding to the agent.
  if M._try_handle_client_command(inst, text) then
    inst.prompt:clear()
    return
  end

  inst.prompt:clear()

  inst.output:follow_tail()
  inst.session:add_user_turn(text)
  inst.output:render_user_turn(text)
  require('cc.statusline_spinner').sync(inst)
  require('cc.statusline').refresh(inst)

  inst.process:write({
    type = 'user',
    session_id = inst.last_session_id or '',
    message = { role = 'user', content = text },
    parent_tool_use_id = vim.NIL,
  })
end

--- Client-side slash command dispatch. Returns true if the text was handled
--- locally (and must not be forwarded to the agent).
---@param inst cc.Instance
---@param text string raw prompt text
---@return boolean handled
function M._try_handle_client_command(inst, text)
  local trimmed = text:match('^%s*(.-)%s*$') or ''
  local cmd, args = trimmed:match('^/([%w_-]+)%s*(.*)$')
  if not cmd then return false end
  if cmd == 'rename' then
    M._handle_rename(inst, args or '')
    return true
  end
  return false
end

--- Apply the session-name-derived buffer name to the prompt buffer. Only
--- the prompt is `buflisted`, so renaming the output (nofile/hide) would not
--- surface anywhere. Test stubs may omit `prompt`, so guard for nil.
---@param inst cc.Instance
---@param name string session title (non-empty)
function M._apply_session_buf_names(inst, name)
  if not name or name == '' then return end
  if inst.prompt and inst.prompt.set_buf_name then
    inst.prompt:set_buf_name('cc-' .. name)
  end
end

--- Persist a user-chosen session title. Matches Claude Code's on-disk format
--- (a `custom-title` JSONL record) so renames are visible from the TUI too.
---@param inst cc.Instance
---@param args string raw arguments after `/rename `
function M._handle_rename(inst, args)
  local name = args:match('^%s*(.-)%s*$') or ''
  local history = require('cc.history')
  local session_id = inst.last_session_id
  if not session_id or session_id == '' then
    inst.output:render_notice('/rename: no session id yet — wait for first response')
    return
  end
  if name == '' then
    local current = inst.session_name
    if current and current ~= '' then
      inst.output:render_notice('/rename: current title is "' .. current .. '" — usage: /rename <name>')
    else
      inst.output:render_notice('/rename: usage: /rename <name>')
    end
    return
  end
  local path = history.session_path(session_id)
  if not path then
    inst.output:render_notice('/rename: transcript not yet on disk — try again after next turn')
    return
  end
  local ok, err = history.append_custom_title(path, session_id, name)
  if not ok then
    inst.output:render_notice('/rename: failed to write title: ' .. tostring(err))
    return
  end
  inst.session_name = name
  M._apply_session_buf_names(inst, name)
  inst.output:render_notice('Session renamed to: ' .. name)
  require('cc.statusline').refresh(inst)
end

--- Public: rename the current session (same code path as `/rename <name>`).
--- Writes a `custom-title` JSONL record so the rename round-trips with the
--- upstream Claude Code TUI. Passing an empty/nil name reports the current
--- title instead of erroring.
---@param name string?
function M.rename(name)
  local inst = get_current_instance()
  if not inst then
    vim.notify('cc.nvim: not open. Run :CcNew first.', vim.log.levels.WARN)
    return
  end
  M._handle_rename(inst, name or '')
end

--- Public: interrupt the current turn without killing the CLI process.
--- Sends a stream-json control_request; the "Interrupted" notice is rendered
--- once the CLI acknowledges with a control_response (see router).
function M.stop()
  local inst = get_current_instance()
  if not inst or not inst.process or not inst.process:is_alive() then return end
  if not inst.session or not inst.session.turn_active then return end
  if inst.session.interrupt_pending then return end
  local request_id = inst.process:send_control_interrupt()
  if request_id then
    inst.session.interrupt_pending = true
    require('cc.statusline').refresh(inst)
  end
end

--- Public: close the current cc.nvim session (kill process, close windows).
function M.close()
  local inst = get_current_instance()
  if not inst then return end
  close_instance(inst)
end

--- Public: toggle visibility (close if current buffer is cc, else open new).
function M.toggle()
  local inst = get_current_instance()
  if inst and inst.process and inst.process:is_alive() then
    close_instance(inst)
  else
    M.open()
  end
end

--- Public: set fold level on the output buffer's window.
---@param level integer 0..3
function M.set_fold_level(level)
  local inst = get_current_instance()
  if inst and inst.output then
    inst.output:set_fold_level(level)
  end
end

--- Public: slash commands available in the current session (for completion).
---@return string[]?
function M.get_slash_commands()
  local inst = get_current_instance()
  if inst and inst.session then return inst.session.slash_commands end
  return nil
end

--- Get the current instance (for dev commands like :CcDumpNdjson).
---@return cc.Instance?
function M._get_instance()
  return get_current_instance()
end

return M
