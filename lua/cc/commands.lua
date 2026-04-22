-- User-facing :Cc* commands.

local M = {}

function M.create()
  local cc = require('cc')

  vim.api.nvim_create_user_command('CcOpen', function() cc.open() end,
    { desc = 'Open cc.nvim' })

  vim.api.nvim_create_user_command('CcClose', function() cc.close() end,
    { desc = 'Close cc.nvim' })

  vim.api.nvim_create_user_command('CcToggle', function() cc.toggle() end,
    { desc = 'Toggle cc.nvim' })

  vim.api.nvim_create_user_command('CcNew', function() cc.new_session() end,
    { desc = 'Start a new cc.nvim session in the current windows' })

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
