-- :checkhealth cc

local M = {}

local function version_ge(v, min)
  local va, vb = v:match('(%d+)%.(%d+)')
  local ma, mb = min:match('(%d+)%.(%d+)')
  va, vb, ma, mb = tonumber(va), tonumber(vb), tonumber(ma), tonumber(mb)
  if not (va and vb and ma and mb) then return false end
  if va ~= ma then return va > ma end
  return vb >= mb
end

function M.check()
  local h = vim.health or require('health')
  h.start('cc.nvim')

  -- Neovim version
  local nvim_version = vim.fn.has('nvim-0.10') == 1 and '0.10+' or 'older'
  if vim.fn.has('nvim-0.10') == 1 then
    h.ok('Neovim ' .. nvim_version .. ' (inline virt_text supported)')
  else
    h.error('Neovim 0.10+ required for inline virt_text carets')
  end

  -- claude binary
  local cmd = require('cc.config').options.claude_cmd
  local exe = vim.fn.exepath(cmd)
  if exe == '' then
    h.error('`' .. cmd .. '` not found in PATH')
    return
  end
  h.ok('claude binary: ' .. exe)

  -- version check
  local version_out = vim.fn.system({ cmd, '--version' })
  local version = version_out:match('(%d+%.%d+%.%d+)')
  if version then
    if version_ge(version, '2.1') then
      h.ok('claude version: ' .. version .. ' (stream-json supported)')
    else
      h.warn('claude version: ' .. version .. ' (may not support --include-partial-messages)')
    end
  else
    h.warn('could not parse claude --version output: ' .. version_out:sub(1, 60))
  end

  -- libuv availability
  if vim.uv or vim.loop then
    h.ok('libuv: available (spawn + pipes work)')
  else
    h.error('libuv not available')
  end

  -- Optional: auth status (best-effort — claude's output format isn't stable)
  h.info('Checking claude auth status...')
  local auth = vim.fn.system({ cmd, 'auth', 'status' })
  if vim.v.shell_error == 0 then
    h.ok('claude auth: ok')
  else
    h.warn('claude auth check failed:\n' .. auth:sub(1, 200))
  end

  -- ---------------------------------------------------------------------------
  -- cc-peek
  -- ---------------------------------------------------------------------------
  h.start('cc-peek')

  local script_path = vim.fn.expand('~/.claude/hooks/cc-peek-wrap.sh')
  local settings_path = vim.fn.expand('~/.claude/settings.json')
  local cache_root = require('cc.peek')._cache_root

  -- 1. Hook script exists and is executable.
  if vim.fn.filereadable(script_path) ~= 1 then
    h.warn('hook script missing at ' .. script_path .. ' — run :CcPeekInstall')
  elseif vim.fn.executable(script_path) ~= 1 then
    h.warn('hook script not executable: ' .. script_path .. ' — run :CcPeekInstall')
  else
    h.ok('hook script: ' .. script_path)
  end

  -- 2. settings.json registers the hook under PreToolUse / Bash.
  local registered = false
  if vim.fn.filereadable(settings_path) == 1 then
    local raw = table.concat(vim.fn.readfile(settings_path), '\n')
    local ok_decode, decoded = pcall(vim.json.decode, raw,
      { luanil = { object = true, array = true } })
    if ok_decode and type(decoded) == 'table'
        and type(decoded.hooks) == 'table'
        and type(decoded.hooks.PreToolUse) == 'table' then
      for _, group in ipairs(decoded.hooks.PreToolUse) do
        if type(group) == 'table' and group.matcher == 'Bash' and type(group.hooks) == 'table' then
          for _, hook in ipairs(group.hooks) do
            if type(hook) == 'table' and hook.command
                and tostring(hook.command):find('cc%-peek%-wrap%.sh') then
              registered = true
              break
            end
          end
        end
        if registered then break end
      end
    end
  end
  if registered then
    h.ok('settings.json: PreToolUse hook registered for Bash')
  else
    h.warn('settings.json: cc-peek hook not registered — run :CcPeekInstall')
  end

  -- 3. Smoke test: invoke the script with a long-timeout Bash payload and
  -- check the output rewrites the command to tee into the cache root.
  if vim.fn.filereadable(script_path) == 1 and vim.fn.executable(script_path) == 1 then
    local payload = vim.json.encode({
      tool_name = 'Bash',
      session_id = 'health',
      tool_use_id = 'smoke',
      tool_input = { command = 'sleep 1', timeout = 60000 },
    })
    local out = vim.fn.system({ script_path }, payload)
    local needle = vim.pesc(cache_root)
    if vim.v.shell_error == 0 and out:find('tee ' .. needle) then
      h.ok('hook script smoke test passed (writes to ' .. cache_root .. ')')
    else
      h.error('hook script smoke test failed: ' .. out:sub(1, 200))
    end
    -- Clean up the dir the smoke test created.
    pcall(vim.fn.delete, cache_root .. '/health', 'rf')
  end

  -- 4. Cache dir permissions (informational — should be 0700 because the
  -- hook script applies umask 077 before mkdir).
  if vim.fn.isdirectory(cache_root) == 1 then
    local mode = vim.fn.getfperm(cache_root)
    if mode == 'rwx------' then
      h.ok('cache root: ' .. cache_root .. ' (perms ' .. mode .. ')')
    else
      h.warn('cache root: ' .. cache_root .. ' (perms ' .. mode .. ' — expected rwx------)')
    end
  else
    h.info('cache root: ' .. cache_root .. ' (not yet created)')
  end

  -- 5. Current-session log dir count (informational).
  local cc = require('cc')
  local inst = cc._get_instance and cc._get_instance() or nil
  local sid = inst and inst.session and inst.session.id or nil
  if sid then
    local dir = cache_root .. '/' .. sid
    if vim.fn.isdirectory(dir) == 1 then
      local files = vim.fn.glob(dir .. '/*.log', false, true)
      h.info(string.format('current session log dir: %s (%d log files)', dir, #files))
    else
      h.info('current session log dir: ' .. dir .. ' (none yet)')
    end
  end
end

return M
