-- Command resolution shared by persistent and one-shot provider processes.
--
-- libuv spawns executables directly, so a configured command such as `cc`
-- would normally resolve to /usr/bin/cc rather than a Bash alias declared in
-- ~/.bash_profile. For bare command names under Bash, launch through a login
-- shell and expand an exact alias match before exec'ing the resulting argv.

local M = {}

local BASH_ALIAS_RUNNER = [=[
name=$1
shift
definition=$(alias "$name" 2>/dev/null)
if [[ -n $definition ]]; then
  replacement=${definition#*=}
  eval "replacement=$replacement"
  eval "set -- $replacement \"\$@\""
  exec "$@"
fi
exec "$name" "$@"
]=]

local function configured_shell()
  local shell = vim.env.SHELL
  if not shell or shell == '' then shell = vim.o.shell end
  return shell
end

local function is_bash(shell)
  return vim.fn.fnamemodify(shell, ':t') == 'bash'
end

--- Resolve a configured command and arguments to a libuv/vim.system argv.
--- Absolute/relative paths stay direct so fixtures and explicit executables
--- do not incur shell startup or profile side effects.
---@param cmd string
---@param args string[]?
---@return string executable
---@return string[] args
function M.resolve(cmd, args)
  args = args or {}
  local shell = configured_shell()
  if cmd:find('/', 1, true) or not is_bash(shell) then
    return cmd, vim.deepcopy(args)
  end

  local resolved_args = {
    '-lc',
    BASH_ALIAS_RUNNER,
    'cc.nvim',
    cmd,
  }
  vim.list_extend(resolved_args, args)
  return shell, resolved_args
end

--- Resolve to the argv-list form accepted by vim.system()/vim.fn.system().
---@param cmd string
---@param args string[]?
---@return string[]
function M.argv(cmd, args)
  local executable, resolved_args = M.resolve(cmd, args)
  local argv = { executable }
  vim.list_extend(argv, resolved_args)
  return argv
end

-- Exposed for a focused subprocess test of alias argv expansion.
M._bash_alias_runner = BASH_ALIAS_RUNNER

return M
