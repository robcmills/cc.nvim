-- cc.nvim: agent CLI chat for Neovim.
-- Spawns the configured provider CLI (`claude` stream-json or `codex
-- app-server`) and renders its stream into buffers. Supports multiple
-- simultaneous sessions, each with its own buffers.

local Config = require('cc.config')
local Session = require('cc.session')
local Output = require('cc.output')
local Prompt = require('cc.prompt')
local Providers = require('cc.providers')

local M = {}

M.VERSION = '0.6.0'

-- ---------------------------------------------------------------------------
-- Instance management
-- ---------------------------------------------------------------------------

---@class cc.Instance
---@field session cc.Session?
---@field provider table? provider instance (cc.ClaudeProvider | cc.CodexProvider)
---@field process table? transport surface (is_alive/close/start_dump/stop_dump); the cc.Process for claude, the provider itself for codex
---@field output cc.Output?
---@field prompt cc.Prompt?
---@field output_winid integer?
---@field prompt_winid integer?
---@field last_session_id string?
---@field last_plan_file string?
---@field session_name string? user-set session title (set via /rename)
---@field pending_session_name string? rename requested before transcript exists; flushed by `_flush_pending_rename`
---@field remote_control_active boolean?
---@field saved_output_view table? output winsaveview snapshot from the last close, restored on reopen
---@field saved_output_following_tail boolean? whether the output cursor was on the tail at the last close; reopen re-pins to the new tail instead of restoring saved_output_view
---@field saved_prompt_view table? prompt winsaveview snapshot from the last close, restored on reopen
---@field last_focus 'prompt'|'output'? which cc buffer the user was last in; restored on reopen
---@field user_fold_level integer? user's chosen foldlevel from the last close, restored on reopen
---@field auto_rename_in_flight boolean? true while the auto-rename subprocess is running
---@field auto_rename_handle userdata? libuv handle of the active auto-rename subprocess
---@field transient_rename_active boolean? true when pending_session_name holds a display-only placeholder that must not be persisted

local instances = {} -- keyed by output bufnr
local next_instance_id = 1

-- Kill claude subprocesses on exit so shada writes complete (avoids E138 .shada.tmp.* orphans).
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('cc.shutdown', { clear = true }),
  callback = function()
    for _, inst in pairs(instances) do
      if inst and inst.process then
        pcall(function() inst.process:close() end)
      end
    end
  end,
})

--- Find the instance that owns the given buffer (output or prompt).
---@param bufnr integer
---@return cc.Instance?
local function find_instance(bufnr)
  if instances[bufnr] then return instances[bufnr] end
  for _, inst in pairs(instances) do
    if inst.prompt and inst.prompt.bufnr == bufnr then return inst end
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
    require('cc.autosize').reset(inst)
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: clear prompt' })
  vim.keymap.set('n', keys.goto_output, function()
    if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid) then
      vim.api.nvim_set_current_win(inst.output_winid)
    end
  end, { buffer = bufnr, silent = true, desc = 'cc.nvim: goto output' })
  if keys.cycle_permission_mode then
    vim.keymap.set({ 'n', 'i' }, keys.cycle_permission_mode,
      function() M.cycle_permission_mode() end,
      { buffer = bufnr, silent = true, desc = 'cc.nvim: cycle permission mode' })
  end
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
  if keys.cycle_permission_mode then
    vim.keymap.set('n', keys.cycle_permission_mode,
      function() M.cycle_permission_mode() end,
      { buffer = bufnr, silent = true, desc = 'cc.nvim: cycle permission mode' })
  end
end

-- ---------------------------------------------------------------------------
-- Buffer sidebar integration autocmds (scoped per-instance)
-- ---------------------------------------------------------------------------

local function setup_buffer_autocmds(inst)
  local output_bufnr = inst.output.bufnr
  local prompt_bufnr = inst.prompt.bufnr
  local group = vim.api.nvim_create_augroup('cc.buffer_integration.' .. output_bufnr, { clear = true })

  -- Record last-focused cc buffer so reopen can restore the user's window
  -- choice. BufLeave fires when leaving the buffer (including hops between
  -- output and prompt), so the value reflects the last position before the
  -- user navigates away from cc entirely. BufEnter would be wrong: it fires
  -- on output during the :bprev-back path (before BufWinEnter recreates the
  -- prompt companion) and would always clobber a prior 'prompt' value.
  vim.api.nvim_create_autocmd('BufLeave', {
    group = group,
    buffer = output_bufnr,
    callback = function() inst.last_focus = 'output' end,
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    group = group,
    buffer = prompt_bufnr,
    callback = function() inst.last_focus = 'prompt' end,
  })

  -- Snapshot both windows' views synchronously while their buffers are still
  -- visible in their respective windows. Either BufWinLeave handler may see
  -- only one of the two buffers still in place (depending on which
  -- nvim_set_current_buf / :edit fired first), so each handler captures
  -- whichever views it can — saved_output_view and saved_prompt_view are
  -- restored together on reopen.
  local function snapshot_views()
    if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid)
        and vim.api.nvim_win_get_buf(inst.output_winid) == output_bufnr then
      local ok, view = pcall(vim.api.nvim_win_call, inst.output_winid, vim.fn.winsaveview)
      if ok then
        inst.saved_output_view = view
        -- Was the user following the tail (cursor on/after the last line)?
        -- If so, reopen must re-pin to the *new* tail rather than restore this
        -- now-stale view: an agent turn that keeps streaming while the layout
        -- is collapsed grows the buffer past the saved cursor line, and
        -- restoring it verbatim would freeze the window above the live tail.
        local line_count = vim.api.nvim_buf_line_count(output_bufnr)
        inst.saved_output_following_tail = view.lnum >= line_count
      end
    end
    if inst.prompt_winid and vim.api.nvim_win_is_valid(inst.prompt_winid)
        and vim.api.nvim_win_get_buf(inst.prompt_winid) == prompt_bufnr then
      local ok, view = pcall(vim.api.nvim_win_call, inst.prompt_winid, vim.fn.winsaveview)
      if ok then inst.saved_prompt_view = view end
    end
  end

  -- When output leaves a window, close the prompt companion (unless moving to prompt).
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = output_bufnr,
    callback = function()
      snapshot_views()
      vim.schedule(function()
        local cur_buf = vim.api.nvim_get_current_buf()
        if cur_buf == prompt_bufnr then return end
        if inst.prompt_winid and vim.api.nvim_win_is_valid(inst.prompt_winid) then
          if vim.api.nvim_win_get_buf(inst.prompt_winid) == prompt_bufnr then
            vim.api.nvim_win_close(inst.prompt_winid, true)
          end
        end
        inst.prompt_winid = nil
        inst.output_winid = nil
      end)
    end,
  })

  -- When prompt leaves a window, close the output companion (unless moving to output).
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = prompt_bufnr,
    callback = function()
      snapshot_views()
      vim.schedule(function()
        local cur_buf = vim.api.nvim_get_current_buf()
        if cur_buf == output_bufnr then return end
        if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid) then
          if vim.api.nvim_win_get_buf(inst.output_winid) == output_bufnr then
            vim.api.nvim_win_close(inst.output_winid, true)
          end
        end
        inst.prompt_winid = nil
        inst.output_winid = nil
      end)
    end,
  })

  -- When output enters a window, recreate the prompt companion below.
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = output_bufnr,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(prompt_bufnr) then return end
        -- Fixture-loaded sessions have no process; gate only on liveness for
        -- real sessions so the prompt companion still reopens for fixtures.
        if not inst.is_fixture and (not inst.process or not inst.process:is_alive()) then
          return
        end
        if inst.prompt_winid and vim.api.nvim_win_is_valid(inst.prompt_winid) then
          return
        end
        local output_win = nil
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(win) == output_bufnr then
            output_win = win
            break
          end
        end
        if not output_win then return end
        -- Capture last_focus before any layout work: the steps below
        -- (split + nvim_set_current_buf(prompt) + nvim_set_current_win(output))
        -- fire BufLeave on cc-nvim-prompt as a side effect, which would
        -- overwrite inst.last_focus to 'prompt' regardless of where the
        -- user actually was.
        local saved_last_focus = inst.last_focus
        inst.output_winid = output_win
        inst.output:set_window(output_win)
        vim.api.nvim_set_current_win(output_win)
        vim.cmd('belowright split')
        vim.api.nvim_set_current_buf(prompt_bufnr)
        inst.prompt_winid = vim.api.nvim_get_current_win()
        inst.prompt:set_window(inst.prompt_winid)
        vim.api.nvim_win_set_height(inst.prompt_winid,
          inst.expected_prompt_height or Config.options.prompt_height)
        require('cc.statusline').attach(inst, output_win)
        -- If the user was last focused on the prompt window, leave focus
        -- there. Default (saved_last_focus nil or 'output') hops back to output.
        if saved_last_focus ~= 'prompt'
            and inst.output_winid
            and vim.api.nvim_win_is_valid(inst.output_winid) then
          vim.api.nvim_set_current_win(inst.output_winid)
        end
        -- New windows on an existing buffer start with cursor at line 1.
        -- Restore the prior views (if snapshotted) so output's scroll and a
        -- half-typed prompt's cursor/scroll survive close/reopen. If output
        -- has no snapshot (first display), anchor it to the last line so
        -- fresh sessions show the most recent content. Schedule so the fix
        -- runs after layout settles (split + resize + nested BufWinEnter
        -- autocmds all complete first).
        local output_winid = inst.output_winid
        local prompt_winid = inst.prompt_winid
        local saved_output_view = inst.saved_output_view
        local saved_output_following_tail = inst.saved_output_following_tail
        local saved_prompt_view = inst.saved_prompt_view
        inst.saved_output_view = nil
        inst.saved_output_following_tail = nil
        inst.saved_prompt_view = nil
        vim.schedule(function()
          if output_winid and vim.api.nvim_win_is_valid(output_winid)
              and vim.api.nvim_win_get_buf(output_winid) == output_bufnr then
            pcall(vim.api.nvim_win_call, output_winid, function()
              -- Re-pin to the tail when the user was following it on leave (the
              -- saved view points at a now-stale line if the buffer grew while
              -- the layout was collapsed); otherwise restore their exact
              -- scroll position.
              if saved_output_view and not saved_output_following_tail then
                vim.fn.winrestview(saved_output_view)
              else
                local last = vim.api.nvim_buf_line_count(output_bufnr)
                vim.api.nvim_win_set_cursor(output_winid, { last, 0 })
                vim.cmd('normal! zb')
              end
            end)
          end
          if saved_prompt_view and prompt_winid and vim.api.nvim_win_is_valid(prompt_winid)
              and vim.api.nvim_win_get_buf(prompt_winid) == prompt_bufnr then
            pcall(vim.api.nvim_win_call, prompt_winid, function()
              vim.fn.winrestview(saved_prompt_view)
            end)
          end
        end)
      end)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Instance creation + teardown
-- ---------------------------------------------------------------------------

--- Create a new instance with layout: output above (primary), prompt below (companion).
---@param opts { reuse_prompt_winid: integer?, reuse_output_winid: integer? }?
---@return cc.Instance
local function create_instance(opts)
  opts = opts or {}
  local id = next_instance_id
  next_instance_id = next_instance_id + 1

  local output_name = id == 1 and 'cc-nvim-output' or ('cc-nvim-output-' .. id)
  local prompt_name = id == 1 and 'cc-nvim-prompt' or ('cc-nvim-prompt-' .. id)

  local inst = {
    session = Session.new(),
    provider = nil,
    process = nil,
    output = nil,
    prompt = nil,
    output_winid = nil,
    prompt_winid = nil,
    last_session_id = nil,
    last_plan_file = nil,
    session_name = nil,
    pending_session_name = nil,
    autosize_disabled = false,
    expected_prompt_height = Config.options.prompt_height,
  }

  -- Snapshot the user's window-local option defaults BEFORE any cc
  -- autocmd fires. The output buffer's BufWinEnter (triggered by the
  -- nvim_set_current_buf below) sets cc's overrides, which for some
  -- "g+l" options like 'number' clobbers vim.go too — so reading defaults
  -- after that point doesn't recover the user's intent. The prompt uses
  -- these as a restore baseline on BufWinLeave because the :split below
  -- makes it inherit cc's overrides from output.
  inst.user_winopts = (function()
    local source = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(source) then return {} end
    local names = {
      'foldmethod', 'foldexpr', 'foldenable', 'foldtext', 'foldlevel',
      'fillchars', 'winhighlight',
      'number', 'relativenumber', 'signcolumn', 'wrap',
    }
    local snap = {}
    for _, n in ipairs(names) do snap[n] = vim.wo[source][n] end
    return snap
  end)()

  inst.output = Output.new(inst.session, output_name)
  inst.prompt = Prompt.new(prompt_name)

  local output_buf = inst.output:ensure_buffer()
  local prompt_buf = inst.prompt:ensure_buffer()

  -- Register the instance before laying out windows. Prompt's BufWinEnter
  -- (fired once the buffer is shown below) needs to look up inst via
  -- find_instance to read inst.user_winopts as its restore baseline.
  instances[output_buf] = inst

  local reuse_prompt = opts.reuse_prompt_winid
  local reuse_output = opts.reuse_output_winid
  if reuse_prompt and not vim.api.nvim_win_is_valid(reuse_prompt) then reuse_prompt = nil end
  if reuse_output and not vim.api.nvim_win_is_valid(reuse_output) then reuse_output = nil end

  if reuse_prompt and reuse_output then
    -- Reuse existing windows: swap new buffers into place.
    vim.api.nvim_win_set_buf(reuse_output, output_buf)
    inst.output_winid = reuse_output
    inst.output:set_window(reuse_output)

    vim.api.nvim_win_set_buf(reuse_prompt, prompt_buf)
    inst.prompt_winid = reuse_prompt
    inst.prompt:set_window(reuse_prompt)

    vim.api.nvim_set_current_win(reuse_prompt)
    vim.api.nvim_win_set_height(reuse_prompt, Config.options.prompt_height)
  else
    -- Stage prompt in the user's current window first, then split aboveleft
    -- to create the output window above. Output ends up in the freshly-
    -- created window; prompt sits in the original window. Both buffers
    -- source their winopts restore baseline from inst.user_winopts because
    -- by the time their BufWinEnter handlers fire, both windows have
    -- already inherited cc's overrides (prompt directly via its own
    -- BufWinEnter, output indirectly via :split inheritance).
    vim.api.nvim_set_current_buf(prompt_buf)
    inst.prompt_winid = vim.api.nvim_get_current_win()
    inst.prompt:set_window(inst.prompt_winid)

    vim.cmd('aboveleft split')
    vim.api.nvim_set_current_buf(output_buf)
    inst.output_winid = vim.api.nvim_get_current_win()
    inst.output:set_window(inst.output_winid)

    -- Return focus to prompt and resize it.
    vim.api.nvim_set_current_win(inst.prompt_winid)
    vim.api.nvim_win_set_height(inst.prompt_winid, Config.options.prompt_height)

    -- Start in insert mode in prompt buffer for immediate typing.
    vim.cmd('startinsert')
  end

  setup_prompt_keymaps(inst)
  setup_output_keymaps(inst)

  -- Set up autocmds after layout to avoid double-trigger from initial BufWinEnter.
  setup_buffer_autocmds(inst)
  require('cc.autosize').attach(inst)
  require('cc.placeholder').attach(inst.prompt.bufnr)

  -- Attach cc statusline to the output window so it renders at the output's
  -- own bottom edge. Requires laststatus=2 (set by attach).
  if inst.output_winid then
    require('cc.statusline').attach(inst, inst.output_winid)
  end

  -- When opening a new instance while the user was focused in a prior
  -- instance's output window, that output's BufWinLeave autocmd schedules
  -- closing the old prompt window. With equalalways on (default), that
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
--- Wipes the old buffers so a renamed output buffer (e.g. `cc-foo`) does not
--- linger and block a future :CcResume of the same session from claiming
--- that name (E95: buffer with this name already exists).
---@param inst cc.Instance
local function teardown_instance_keep_windows(inst)
  require('cc.statusline_spinner').stop(inst)
  if inst.output and inst.output.bufnr > 0 then
    local sid = inst.session and inst.session.id or nil
    pcall(function() require('cc.peek').teardown(inst.output.bufnr, sid) end)
  end
  if inst.process then
    inst.process:close()
    inst.process = nil
  end
  if inst.output and inst.output.bufnr > 0 then
    pcall(vim.api.nvim_del_augroup_by_name, 'cc.buffer_integration.' .. inst.output.bufnr)
  end
  if inst.prompt and inst.prompt.bufnr > 0 then
    require('cc.autosize').detach(inst.prompt.bufnr)
    require('cc.placeholder').detach(inst.prompt.bufnr)
  end
  if inst.output and inst.output.bufnr > 0 then
    instances[inst.output.bufnr] = nil
    if vim.api.nvim_buf_is_valid(inst.output.bufnr) then
      pcall(vim.api.nvim_buf_delete, inst.output.bufnr, { force = true })
    end
  end
  if inst.prompt and inst.prompt.bufnr and vim.api.nvim_buf_is_valid(inst.prompt.bufnr) then
    pcall(vim.api.nvim_buf_delete, inst.prompt.bufnr, { force = true })
  end
end

--- Tear down an instance: kill process, close windows, wipe buffers, remove from table.
--- Wiping (rather than just unlisting) frees the buffer name so a later
--- :CcResume of a renamed session can rename its new output buffer to the
--- same `cc-<title>` without colliding with the stale buffer.
---@param inst cc.Instance
local function close_instance(inst)
  require('cc.statusline_spinner').stop(inst)
  if inst.output and inst.output.bufnr > 0 then
    local sid = inst.session and inst.session.id or nil
    pcall(function() require('cc.peek').teardown(inst.output.bufnr, sid) end)
  end
  if inst.process then
    inst.process:close()
    inst.process = nil
  end
  require('cc.auto_rename').cancel(inst)
  -- Clear per-instance autocmds before closing windows to avoid cascading.
  if inst.output and inst.output.bufnr > 0 then
    pcall(vim.api.nvim_del_augroup_by_name, 'cc.buffer_integration.' .. inst.output.bufnr)
  end
  if inst.prompt and inst.prompt.bufnr > 0 then
    require('cc.autosize').detach(inst.prompt.bufnr)
    require('cc.placeholder').detach(inst.prompt.bufnr)
  end
  if inst.prompt_winid and vim.api.nvim_win_is_valid(inst.prompt_winid) then
    pcall(vim.api.nvim_win_close, inst.prompt_winid, true)
  end
  if inst.output_winid and vim.api.nvim_win_is_valid(inst.output_winid) then
    pcall(vim.api.nvim_win_close, inst.output_winid, true)
  end
  if inst.output and inst.output.bufnr > 0 then
    instances[inst.output.bufnr] = nil
    if vim.api.nvim_buf_is_valid(inst.output.bufnr) then
      pcall(vim.api.nvim_buf_delete, inst.output.bufnr, { force = true })
    end
  end
  if inst.prompt and inst.prompt.bufnr and vim.api.nvim_buf_is_valid(inst.prompt.bufnr) then
    pcall(vim.api.nvim_buf_delete, inst.prompt.bufnr, { force = true })
  end
  inst.output_winid = nil
  inst.prompt_winid = nil
  inst.session = nil
  inst.output = nil
  inst.prompt = nil
  inst.provider = nil
end

-- ---------------------------------------------------------------------------
-- Provider wiring
-- ---------------------------------------------------------------------------

--- Build, wire, and spawn the configured provider for an instance. Shared
--- by open, new_session, and resume so lifecycle handling lives in one place.
---@param inst cc.Instance
---@param opts { resume_id: string?, permission_mode: string? }?
---@return boolean ok
local function attach_provider(inst, opts)
  opts = opts or {}
  local P, perr = Providers.current()
  if not P then
    vim.notify('cc.nvim: ' .. tostring(perr), vim.log.levels.ERROR)
    return false
  end
  local provider = P.attach({
    instance = inst,
    session = inst.session,
    output = inst.output,
    resume_id = opts.resume_id,
    permission_mode = opts.permission_mode,
    on_session_id = function(id)
      inst.last_session_id = id
      require('cc.statusline').refresh(inst)
    end,
    on_exit = function(code)
      if code and code ~= 0 then
        vim.notify('cc.nvim: ' .. P.name .. ' exited with code ' .. code, vim.log.levels.WARN)
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
  inst.provider = provider
  -- Transport surface for callers that talk to inst.process directly
  -- (teardown, :CcDumpNdjson, is_alive checks, VimLeavePre kill).
  inst.process = provider.process or provider

  local ok, err = pcall(function() provider:spawn() end)
  if not ok then
    vim.notify('cc.nvim: ' .. tostring(err), vim.log.levels.ERROR)
    inst.provider = nil
    inst.process = nil
    return false
  end
  return true
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
  require('cc.splash').render(inst.output.bufnr)
  attach_provider(inst, { permission_mode = opts.permission_mode })
end

--- Public: open in plan mode (Claude-only).
function M.plan()
  local P = Providers.current()
  if P and not P.capabilities.plan_mode then
    vim.notify('cc.nvim: plan mode is not supported by the ' .. P.name .. ' provider',
      vim.log.levels.WARN)
    return
  end
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
  require('cc.splash').render(new_inst.output.bufnr)
  attach_provider(new_inst)
end

-- Placeholder shown in the prompt buffer of a fixture-loaded session, also
-- echoed if the user attempts to submit.
local FIXTURE_PLACEHOLDER = 'Viewing static fixture. Prompt submission disabled.'

--- Resolve a fixture name or path to (absolute_path, fixture_type).
--- Bare names search tests/fixtures/{jsonl,ndjson} via &runtimepath.
---@param name_or_path string
---@return string? path
---@return string? ftype 'jsonl' | 'ndjson'
local function resolve_fixture(name_or_path)
  local has_slash = name_or_path:find('/', 1, true) ~= nil
  if has_slash then
    local path = vim.fn.fnamemodify(vim.fn.expand(name_or_path), ':p')
    if path:match('%.jsonl$') then return path, 'jsonl' end
    if path:match('%.ndjson$') then return path, 'ndjson' end
    return path, nil
  end

  local base = name_or_path:gsub('%.jsonl$', ''):gsub('%.ndjson$', '')
  local jsonl = vim.api.nvim_get_runtime_file('tests/fixtures/jsonl/' .. base .. '.jsonl', false)
  local ndjson = vim.api.nvim_get_runtime_file('tests/fixtures/ndjson/' .. base .. '.ndjson', false)

  -- Honor explicit extension; otherwise prefer JSONL (matches `--visual`).
  if name_or_path:match('%.ndjson$') then
    if ndjson[1] then return ndjson[1], 'ndjson' end
  elseif name_or_path:match('%.jsonl$') then
    if jsonl[1] then return jsonl[1], 'jsonl' end
  else
    if jsonl[1] then return jsonl[1], 'jsonl' end
    if ndjson[1] then return ndjson[1], 'ndjson' end
  end
  return nil, nil
end

--- Public: load a test fixture into a fresh cc.nvim session for visual
--- inspection. No `claude` subprocess is spawned; submission is disabled.
---
--- Resolution:
---   * Paths containing `/` are treated as paths and used as-is.
---   * Bare names search `tests/fixtures/jsonl/<name>.jsonl`, then
---     `tests/fixtures/ndjson/<name>.ndjson`, via &runtimepath.
---   * The `.jsonl` / `.ndjson` extension may be included to disambiguate.
---@param name_or_path string
function M.load_fixture(name_or_path)
  if not name_or_path or name_or_path == '' then
    vim.notify('cc.nvim: load_fixture requires a fixture name or path', vim.log.levels.WARN)
    return
  end

  local path, ftype = resolve_fixture(name_or_path)
  if not path or vim.fn.filereadable(path) == 0 then
    vim.notify('cc.nvim: fixture not found: ' .. name_or_path, vim.log.levels.WARN)
    return
  end
  if not ftype then
    vim.notify('cc.nvim: fixture must end in .jsonl or .ndjson', vim.log.levels.WARN)
    return
  end

  local inst = create_instance()
  inst.is_fixture = true
  inst.fixture_path = path

  local fixture_name = vim.fn.fnamemodify(path, ':t:r')
  inst.session_name = fixture_name
  M._apply_session_buf_names(inst, fixture_name)

  require('cc.placeholder').set_text(inst.prompt.bufnr, FIXTURE_PLACEHOLDER)

  if ftype == 'jsonl' then
    local history = require('cc.history')
    local records = history.read_transcript(path)
    for _, rec in ipairs(records) do
      inst.output:render_historical_record(rec)
    end
  else
    inst.router = require('cc.router').new({
      session = inst.session,
      output = inst.output,
      instance = inst,
    })
    local Parser = require('cc.parser')
    local parser = Parser.new()
    local lines = vim.fn.readfile(path)
    for _, line in ipairs(lines) do
      local messages = parser:feed(line .. '\n')
      for _, msg in ipairs(messages) do
        inst.router:dispatch(msg)
      end
    end
  end

  inst.output:render_notice('fixture: ' .. vim.fn.fnamemodify(path, ':t'))
  require('cc.statusline').refresh(inst)
end

--- Public: resume a specific session by id (Claude session id or Codex
--- thread id, depending on the configured provider).
---@param session_id string
function M.resume(session_id)
  if not session_id or session_id == '' then
    vim.notify('cc.nvim: resume requires a session id', vim.log.levels.WARN)
    return
  end

  local P, perr = Providers.current()
  if not P then
    vim.notify('cc.nvim: ' .. tostring(perr), vim.log.levels.ERROR)
    return
  end

  local inst = create_instance()
  -- Pre-render transcript so the UI shows past conversation. Claude reads
  -- the local JSONL; Codex replays history from the thread/resume response
  -- once the app-server connects.
  if P.prerender_resume then
    P.prerender_resume(inst, session_id)
  end
  inst.last_session_id = session_id
  attach_provider(inst, { resume_id = session_id })
end

--- Public: resume most recent session for the current cwd.
function M.continue_last()
  local P, perr = Providers.current()
  if not P then
    vim.notify('cc.nvim: ' .. tostring(perr), vim.log.levels.ERROR)
    return
  end
  P.list_history({ all = false }, function(entries)
    if #entries == 0 then
      vim.notify('cc.nvim: no prior sessions for this cwd', vim.log.levels.INFO)
      return
    end
    M.resume(entries[1].session_id)
  end)
end

--- Public: pick a session to resume.
---@param all_projects boolean? if true, include sessions from other cwds
function M.history(all_projects)
  local P, perr = Providers.current()
  if not P then
    vim.notify('cc.nvim: ' .. tostring(perr), vim.log.levels.ERROR)
    return
  end
  P.list_history({ all = all_projects or false }, function(entries)
    if #entries == 0 then
      vim.notify('cc.nvim: no sessions found', vim.log.levels.INFO)
      return
    end
    require('cc.picker').select(entries, {
      prompt = all_projects and 'Resume session (all projects)' or 'Resume session',
      format_item = function(e) return P.format_history_entry(e, all_projects or false) end,
    }, function(choice)
      if choice then M.resume(choice.session_id) end
    end)
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
  if inst and inst.is_fixture then
    vim.notify(FIXTURE_PLACEHOLDER, vim.log.levels.WARN)
    return
  end
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
    require('cc.autosize').reset(inst)
    return
  end

  -- First-turn auto-rename (best-effort, before turns is incremented).
  -- Skipped for providers that don't support it (codex threads get named
  -- via /rename → thread/name/set instead).
  local caps = inst.provider and inst.provider.capabilities or {}
  local AutoRename = require('cc.auto_rename')
  if caps.auto_rename ~= false and AutoRename.should_run(inst) then
    AutoRename.start(inst, text)
  end

  inst.prompt:clear()
  require('cc.autosize').reset(inst)

  require('cc.splash').clear(inst.output.bufnr)
  inst.output:follow_tail()
  inst.session:add_user_turn(text)
  inst.output:render_user_turn(text)
  require('cc.statusline_spinner').sync(inst)
  require('cc.statusline').refresh(inst)

  if inst.provider then
    inst.provider:send(text)
  else
    -- Test stubs register instances with a bare process; keep the legacy
    -- direct-write path working for them.
    inst.process:write({
      type = 'user',
      session_id = inst.last_session_id or '',
      message = { role = 'user', content = text },
      parent_tool_use_id = vim.NIL,
    })
  end
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
  if cmd == 'effort' then
    M._handle_effort(inst, args or '')
    return true
  end
  return false
end

--- Set or report the reasoning effort level. In-memory and session-scoped
--- (not persisted to disk); applied to the next spawned claude process via
--- CLAUDE_CODE_EFFORT_LEVEL.
---@param inst cc.Instance?
---@param args string raw arguments after `/effort` or `:CcEffort`
function M._handle_effort(inst, args)
  local Effort = require('cc.effort')
  local arg = (args or ''):match('^%s*(.-)%s*$')
  if arg == '' then
    vim.notify(
      'cc.nvim effort: ' .. Effort.get() ..
      '  (levels: ' .. table.concat(Effort.levels(), ', ') .. ')',
      vim.log.levels.INFO)
    return
  end
  if not Effort.is_valid(arg) then
    vim.notify(
      'cc.nvim effort: invalid level "' .. arg .. '". ' ..
      'Use one of: ' .. table.concat(Effort.levels(), ', '),
      vim.log.levels.WARN)
    return
  end
  Effort.set(arg)
  local scope_note = ' (applies to next claude spawn — :CcClear or restart to take effect)'
  if inst and inst.provider and inst.provider.name == 'codex' then
    scope_note = ' (applies from the next codex turn)'
  elseif Providers.current_name() == 'codex' then
    scope_note = ' (applies from the next codex turn)'
  end
  vim.notify('cc.nvim: effort set to ' .. arg .. scope_note, vim.log.levels.INFO)
  if inst then
    require('cc.statusline').refresh(inst)
  end
end

--- Public: set or report the reasoning effort level (same as `/effort`).
---@param level string?
function M.effort(level)
  M._handle_effort(get_current_instance(), level or '')
end

--- Permission modes accepted by `claude --permission-mode` and the
--- `set_permission_mode` control_request. Order matches the picker layout.
M.PERMISSION_MODES = {
  'acceptEdits',
  'auto',
  'bypassPermissions',
  'default',
  'dontAsk',
  'plan',
}

---@param mode string
---@return boolean
local function is_valid_permission_mode(mode)
  for _, m in ipairs(M.PERMISSION_MODES) do
    if m == mode then return true end
  end
  return false
end

--- True when the active context (live instance, else configured provider)
--- supports Claude permission modes. Notifies with guidance when it doesn't.
---@param inst cc.Instance?
---@return boolean
local function permission_modes_supported(inst)
  local caps
  if inst and inst.provider then
    caps = inst.provider.capabilities
  else
    local P = Providers.current()
    caps = P and P.capabilities
  end
  if caps and caps.permission_modes == false then
    vim.notify(
      'cc.nvim: permission modes are Claude-specific. For codex, configure '
      .. 'providers.codex.approval_policy / providers.codex.sandbox instead.',
      vim.log.levels.WARN)
    return false
  end
  return true
end

--- Apply a permission_mode choice: if an active session is in the current
--- buffer, send a set_permission_mode control_request so the live CLI
--- switches without restart. Otherwise persist on Config.options so the
--- next :Cc / :CcNew picks it up.
---@param mode string
local function apply_permission_mode(mode)
  local inst = get_current_instance()
  if not permission_modes_supported(inst) then return end
  if inst and inst.process and inst.process:is_alive() then
    local request_id
    if inst.provider and inst.provider.set_permission_mode then
      request_id = inst.provider:set_permission_mode(mode)
    elseif inst.process.send_control_set_permission_mode then
      request_id = inst.process:send_control_set_permission_mode(mode)
    end
    if request_id then
      vim.notify('cc.nvim: permission_mode → ' .. mode, vim.log.levels.INFO)
    end
    return
  end
  Config.options.permission_mode = mode
  vim.notify(
    'cc.nvim: permission_mode set to ' .. mode .. ' (applies to next :Cc / :CcNew)',
    vim.log.levels.INFO)
end

--- Cycle order matches the upstream Claude Code TUI's Shift+Tab handler for
--- non-ant users (`src/utils/permissions/getNextPermissionMode.ts`). Modes
--- outside the cycle (auto / bypassPermissions / dontAsk) drop back to
--- 'default' on the next press — we deliberately do NOT cycle into
--- bypassPermissions because relaxing safety should be explicit.
local CYCLE_NEXT = {
  default = 'acceptEdits',
  acceptEdits = 'plan',
  plan = 'default',
  auto = 'default',
  bypassPermissions = 'default',
  dontAsk = 'default',
}

--- Public: advance the permission mode one step in the Shift+Tab cycle.
--- Reads the current mode from the active session (if any) or
--- `Config.options.permission_mode` (treating nil as 'default'), then
--- applies the next mode via the same path as `set_permission_mode`.
function M.cycle_permission_mode()
  local inst = get_current_instance()
  local current
  if inst and inst.process and inst.process:is_alive() and inst.session then
    current = inst.session.permission_mode or 'default'
  else
    current = Config.options.permission_mode or 'default'
  end
  local next_mode = CYCLE_NEXT[current] or 'default'
  apply_permission_mode(next_mode)
end

--- Public: set the permission mode. Empty/nil opens a picker; a valid mode
--- string applies it directly. Invalid strings warn and change nothing.
---@param mode string?
function M.set_permission_mode(mode)
  local arg = mode and mode:match('^%s*(.-)%s*$') or ''
  if arg == '' then
    vim.ui.select(M.PERMISSION_MODES, {
      prompt = 'Permission mode',
      format_item = function(item) return item end,
    }, function(choice)
      if choice then apply_permission_mode(choice) end
    end)
    return
  end
  if not is_valid_permission_mode(arg) then
    vim.notify(
      'cc.nvim: invalid permission mode "' .. arg .. '". Use one of: ' ..
      table.concat(M.PERMISSION_MODES, ', '),
      vim.log.levels.WARN)
    return
  end
  apply_permission_mode(arg)
end

--- Apply the session-name-derived buffer name to the output buffer. Only
--- the output is `buflisted`, so renaming the prompt (nofile/hide/unlisted)
--- would not surface anywhere. Test stubs may omit `output`, so guard for nil.
---@param inst cc.Instance
---@param name string session title (non-empty)
function M._apply_session_buf_names(inst, name)
  if not name or name == '' then return end
  if inst.output and inst.output.set_buf_name then
    inst.output:set_buf_name('cc-' .. name)
  end
end

--- Collect session names from every live instance except `exclude`. Used by
--- the rename path to dedupe against in-memory titles that aren't yet on
--- disk (two queued sessions racing before either has a transcript).
---@param exclude cc.Instance?
---@return string[]
function M._live_taken_names(exclude)
  local out = {}
  for _, inst in pairs(instances) do
    if inst ~= exclude then
      if inst.session_name and inst.session_name ~= '' then
        table.insert(out, inst.session_name)
      end
      if inst.pending_session_name and inst.pending_session_name ~= ''
          and not inst.transient_rename_active then
        table.insert(out, inst.pending_session_name)
      end
    end
  end
  return out
end

--- Persist a user-chosen session title. Matches Claude Code's on-disk format
--- (a `custom-title` JSONL record) so renames are visible from the TUI too.
--- If invoked before the transcript exists (fresh session, no first turn yet),
--- the name is stashed on the instance and flushed by `_flush_pending_rename`
--- once the JSONL appears on disk.
---
--- `opts.silent` suppresses user-facing notifications. `opts.transient` makes
--- the call display-only: the placeholder is shown in the statusline via
--- `pending_session_name`, but never persisted to disk and never flushed.
--- The auto-rename feature uses this combination to surface "naming…"
--- feedback while its subprocess runs.
---@param inst cc.Instance
---@param args string raw arguments after `/rename `
---@param opts { silent: boolean?, transient: boolean? }?
function M._handle_rename(inst, args, opts)
  opts = opts or {}
  local name = args:match('^%s*(.-)%s*$') or ''
  local history = require('cc.history')
  local session_id = inst.last_session_id
  if name == '' then
    local current = inst.session_name
    local pending = inst.pending_session_name
    if pending and pending ~= '' then
      vim.notify('cc.nvim /rename: pending title is "' .. pending .. '" (will persist when session begins) — usage: /rename <name>', vim.log.levels.INFO)
    elseif current and current ~= '' then
      vim.notify('cc.nvim /rename: current title is "' .. current .. '" — usage: /rename <name>', vim.log.levels.INFO)
    else
      vim.notify('cc.nvim /rename: usage: /rename <name>', vim.log.levels.INFO)
    end
    return
  end
  if opts.transient then
    -- Display-only placeholder: surface via pending_session_name so the
    -- statusline picks it up, but mark the instance so flush + auto-rename
    -- callback know this name must never be persisted. Skips dedupe because
    -- the placeholder string is configured per-user and is never written.
    inst.pending_session_name = name
    inst.transient_rename_active = true
    M._apply_session_buf_names(inst, name)
    require('cc.statusline').refresh(inst)
    return
  end
  -- Any prior transient placeholder is being replaced by a real rename.
  inst.transient_rename_active = nil

  -- Provider-native rename (codex: thread/name/set). The provider owns
  -- persistence; no local JSONL is written and no cwd-wide dedupe applies.
  if inst.provider and inst.provider.rename then
    local function apply_locally()
      inst.session_name = name
      inst.pending_session_name = nil
      M._apply_session_buf_names(inst, name)
      require('cc.statusline').refresh(inst)
    end
    local sent = inst.provider:rename(name, function(rok, rerr)
      if not rok and not opts.silent then
        vim.notify('cc.nvim /rename: ' .. tostring(rerr or 'rename failed'), vim.log.levels.ERROR)
      end
    end)
    if sent then
      apply_locally()
      if not opts.silent then
        vim.notify('cc.nvim: session renamed to "' .. name .. '"', vim.log.levels.INFO)
      end
    else
      -- Thread not started yet: queue and flush once the session begins.
      inst.pending_session_name = name
      M._apply_session_buf_names(inst, name)
      require('cc.statusline').refresh(inst)
      if not opts.silent then
        vim.notify('cc.nvim: rename queued — will persist when session begins', vim.log.levels.INFO)
      end
    end
    return
  end

  -- Resolve a unique title before persisting or naming the buffer. Without
  -- this, two sessions sharing a name collide both in the picker and in the
  -- `cc-<title>` buffer namespace (E95 from nvim_buf_set_name).
  name = history.find_unique_session_name(name, nil, session_id, M._live_taken_names(inst))
  local path = session_id and session_id ~= '' and history.session_path(session_id) or nil
  if not path then
    -- Pre-begin or transcript not yet flushed: stash the name and rename the
    -- buffer immediately for visual feedback. `_flush_pending_rename` will
    -- persist it on the next router event that proves the file exists.
    inst.pending_session_name = name
    M._apply_session_buf_names(inst, name)
    require('cc.statusline').refresh(inst)
    if not opts.silent then
      vim.notify('cc.nvim: rename queued — will persist when session begins', vim.log.levels.INFO)
    end
    return
  end
  local ok, err = history.append_custom_title(path, session_id, name)
  if not ok then
    vim.notify('cc.nvim /rename: failed to write title: ' .. tostring(err), vim.log.levels.ERROR)
    return
  end
  inst.session_name = name
  inst.pending_session_name = nil
  M._apply_session_buf_names(inst, name)
  if not opts.silent then
    vim.notify('cc.nvim: session renamed to "' .. name .. '"', vim.log.levels.INFO)
  end
  require('cc.statusline').refresh(inst)
end

--- Flush a pending pre-begin rename to disk if both the name and the
--- transcript file are now available. Silent on no-op; warns only on
--- write failure. Safe to call from any router event.
---
--- A transient placeholder (set by auto-rename to show "naming…" feedback)
--- is intentionally skipped — it lives in `pending_session_name` for the
--- statusline's benefit but must never be persisted.
---@param inst cc.Instance
function M._flush_pending_rename(inst)
  if inst and inst.transient_rename_active then return end
  local name = inst and inst.pending_session_name
  if not name or name == '' then return end
  -- Provider-native rename (codex): flush through thread/name/set.
  if inst.provider and inst.provider.rename then
    local sent = inst.provider:rename(name, function() end)
    if sent then
      inst.session_name = name
      inst.pending_session_name = nil
      M._apply_session_buf_names(inst, name)
      require('cc.statusline').refresh(inst)
    end
    return
  end
  local session_id = inst.last_session_id
  if not session_id or session_id == '' then return end
  local history = require('cc.history')
  local path = history.session_path(session_id)
  if not path then return end
  -- Re-dedupe at flush time: other sessions may have claimed the queued name
  -- between the original `/rename` and now.
  name = history.find_unique_session_name(name, nil, session_id, M._live_taken_names(inst))
  local ok, err = history.append_custom_title(path, session_id, name)
  if not ok then
    vim.notify('cc.nvim /rename: failed to write queued title: ' .. tostring(err), vim.log.levels.ERROR)
    inst.pending_session_name = nil
    return
  end
  inst.session_name = name
  inst.pending_session_name = nil
  M._apply_session_buf_names(inst, name)
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
--- Routed through the provider (claude: interrupt control_request; codex:
--- turn/interrupt). The "Interrupted" notice renders on acknowledgement.
function M.stop()
  local inst = get_current_instance()
  if not inst or not inst.process or not inst.process:is_alive() then return end
  if not inst.session or not inst.session.turn_active then return end
  if inst.session.interrupt_pending then return end
  local sent
  if inst.provider then
    sent = inst.provider:interrupt()
  else
    sent = inst.process.send_control_interrupt and inst.process:send_control_interrupt()
  end
  if sent then
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

--- Public: toggle auto-sizing of the prompt window. Pass 'on' or 'off' to
--- set explicitly; nil toggles. Notifies the new state.
---@param state 'on'|'off'|nil
function M.prompt_autosize(state)
  local inst = get_current_instance()
  if not inst then
    vim.notify('cc.nvim: not in a cc buffer', vim.log.levels.WARN)
    return
  end
  local enabled = require('cc.autosize').toggle(inst, state)
  vim.notify('cc.nvim: prompt autosize ' .. (enabled and 'on' or 'off'), vim.log.levels.INFO)
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

--- Public: user-invocable skills available in the current session.
---@return string[]?
function M.get_skills()
  local inst = get_current_instance()
  if inst and inst.session then return inst.session.skills end
  return nil
end

--- Get the current instance (for dev commands like :CcDumpNdjson).
---@return cc.Instance?
function M._get_instance()
  return get_current_instance()
end

--- Test-only: clear the module-level instances registry. Allows a shared
--- test nvim to simulate fresh module state across cases.
function M._reset_instances()
  for k in pairs(instances) do instances[k] = nil end
  next_instance_id = 1
end

--- Test-only: register a fake instance keyed by `bufnr`. Lets specs drive
--- code paths that route through `get_current_instance()` without spawning
--- a real claude subprocess.
---@param bufnr integer
---@param inst table
function M._register_test_instance(bufnr, inst)
  instances[bufnr] = inst
end

return M
