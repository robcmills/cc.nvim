-- User-facing :Cc* commands.

local M = {}

function M.create()
  local cc = require('cc')

  vim.api.nvim_create_user_command('CcNew', function(opts)
    if #opts.fargs > 2 then
      vim.notify('cc.nvim: :CcNew [model] [effort]', vim.log.levels.WARN)
      return
    end
    local model, effort = opts.fargs[1], opts.fargs[2]
    if effort and not require('cc.effort').is_valid(effort) then
      vim.notify(
        'cc.nvim: invalid effort "' .. effort .. '". Use one of: '
        .. table.concat(require('cc.effort').levels(), ', '),
        vim.log.levels.WARN)
      return
    end
    cc.open({ model = model, effort = effort })
  end, {
    nargs = '*',
    complete = function(arg_lead, cmd_line, cursor_pos)
      local before = cmd_line:sub(1, cursor_pos)
      local args = before:match('^%s*CcNew%s+(.*)$') or ''
      local _, rest = args:match('^(%S+)%s+(.*)$')
      if rest == nil then
        return require('cc.model').complete(arg_lead)
      end
      if rest:find('%s') then return {} end
      local out = {}
      for _, level in ipairs(require('cc.effort').levels()) do
        if level:sub(1, #arg_lead) == arg_lead then table.insert(out, level) end
      end
      return out
    end,
    desc = 'Open cc.nvim with optional model and reasoning effort',
  })

  vim.api.nvim_create_user_command('CcClose', function() cc.close() end,
    { desc = 'Close cc.nvim' })

  vim.api.nvim_create_user_command('CcToggle', function() cc.toggle() end,
    { desc = 'Toggle cc.nvim' })

  vim.api.nvim_create_user_command('CcClear', function() cc.new_session() end,
    { desc = 'Start a fresh cc.nvim session in the current windows' })

  vim.api.nvim_create_user_command('CcSend', function() cc.submit() end,
    { desc = 'Submit prompt to Claude' })

  vim.api.nvim_create_user_command('CcStop', function() cc.stop() end,
    { desc = 'Interrupt current Claude generation' })

  vim.api.nvim_create_user_command('CcFold', function(opts)
    local level = tonumber(opts.args)
    if not level then
      vim.notify('cc.nvim: :CcFold N (0..3)', vim.log.levels.WARN)
      return
    end
    cc.set_fold_level(level)
  end, { nargs = 1, desc = 'Set cc.nvim output fold level (0..3)' })

  vim.api.nvim_create_user_command('CcPlan', function() cc.plan() end,
    { desc = 'Open cc.nvim in plan mode' })

  vim.api.nvim_create_user_command('CcPlanShow', function() cc.plan_show() end,
    { desc = 'Show the most recent plan file (or pick from ~/.claude/plans)' })

  vim.api.nvim_create_user_command('CcResume', function(opts)
    if opts.args and opts.args ~= '' then
      cc.resume(opts.args)
    else
      cc.history(false)
    end
  end, { nargs = '?', desc = 'Resume a cc.nvim session (prompt if no id)' })

  vim.api.nvim_create_user_command('CcContinue', function() cc.continue_last() end,
    { desc = 'Resume most recent cc.nvim session for current cwd' })

  vim.api.nvim_create_user_command('CcHistory', function(opts)
    cc.history(opts.bang)
  end, { bang = true, desc = 'Pick a session to resume (! for all projects)' })

  vim.api.nvim_create_user_command('CcRename', function(opts)
    cc.rename(opts.args)
  end, { nargs = '?', desc = 'Rename current cc.nvim session (no arg shows current)' })

  vim.api.nvim_create_user_command('CcEffort', function(opts)
    cc.effort(opts.args)
  end, {
    nargs = '?',
    complete = function(arg_lead)
      local out = {}
      for _, l in ipairs(require('cc.effort').levels()) do
        if l:sub(1, #arg_lead) == arg_lead then
          table.insert(out, l)
        end
      end
      return out
    end,
    desc = 'Set reasoning effort level (low|medium|high|xhigh|max|auto)',
  })

  vim.api.nvim_create_user_command('CcModel', function(opts)
    cc.model(opts.args)
  end, {
    nargs = '?',
    complete = function(arg_lead)
      local inst = cc._get_instance()
      local provider = inst and inst.provider and inst.provider.name
      return require('cc.model').complete(arg_lead, provider)
    end,
    desc = 'Set the model for subsequent conversation turns',
  })

  vim.api.nvim_create_user_command('CcPermissionMode', function(opts)
    cc.set_permission_mode(opts.args)
  end, {
    nargs = '?',
    complete = function(arg_lead)
      local out = {}
      for _, m in ipairs(cc.PERMISSION_MODES) do
        if m:sub(1, #arg_lead) == arg_lead then
          table.insert(out, m)
        end
      end
      return out
    end,
    desc = 'Set permission mode (acceptEdits|auto|bypassPermissions|default|dontAsk|plan); no arg opens a picker',
  })

  vim.api.nvim_create_user_command('CcPromptAutosize', function(opts)
    local arg = (opts.args or ''):lower()
    if arg ~= '' and arg ~= 'on' and arg ~= 'off' then
      vim.notify('cc.nvim: :CcPromptAutosize [on|off]', vim.log.levels.WARN)
      return
    end
    cc.prompt_autosize(arg == '' and nil or arg)
  end, {
    nargs = '?',
    complete = function() return { 'on', 'off' } end,
    desc = 'Toggle prompt window autosize (on|off)',
  })

  vim.api.nvim_create_user_command('CcLoadFixture', function(opts)
    cc.load_fixture(opts.args)
  end, {
    nargs = 1,
    complete = function(arg_lead)
      local seen, out = {}, {}
      local function add(name)
        if not seen[name] then
          seen[name] = true
          if name:sub(1, #arg_lead) == arg_lead then table.insert(out, name) end
        end
      end
      for _, dir in ipairs({ 'tests/fixtures/jsonl', 'tests/fixtures/ndjson' }) do
        for _, path in ipairs(vim.api.nvim_get_runtime_file(dir, true)) do
          for _, file in ipairs(vim.fn.glob(path .. '/*', false, true)) do
            local base = vim.fn.fnamemodify(file, ':t:r')
            if base ~= 'README' then add(base) end
          end
        end
      end
      table.sort(out)
      return out
    end,
    desc = 'Load a test fixture into a fresh cc.nvim session (read-only)',
  })

  vim.api.nvim_create_user_command('CcStatus', function()
    require('cc.status').open()
  end, { desc = 'Show current cc.nvim session status in a floating window' })

  vim.api.nvim_create_user_command('CcPeek', function()
    require('cc.peek').peek_command()
  end, { desc = 'Tail a running Bash tool call in a floating window' })

  vim.api.nvim_create_user_command('CcPeekInstall', function()
    require('cc.peek').install()
  end, { desc = 'Install the cc-peek PreToolUse hook in ~/.claude/settings.json' })

  vim.api.nvim_create_user_command('CcPeekUninstall', function()
    require('cc.peek').uninstall()
  end, { desc = 'Remove the cc-peek PreToolUse hook from ~/.claude/settings.json' })

  vim.api.nvim_create_user_command('CcDumpNdjson', function(opts)
    local inst = cc._get_instance()
    if not inst or not inst.process then
      vim.notify('cc.nvim: no active process to dump', vim.log.levels.WARN)
      return
    end
    if opts.args and opts.args ~= '' then
      inst.process:start_dump(vim.fn.expand(opts.args))
    else
      inst.process:stop_dump()
    end
  end, { nargs = '?', desc = 'Tee raw NDJSON to file (no arg = stop)' })
end

return M
