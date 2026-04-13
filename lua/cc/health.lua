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
end

return M
