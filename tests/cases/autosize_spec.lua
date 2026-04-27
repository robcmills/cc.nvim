-- Tests for the prompt-window autosize module:
-- * grows to fit content (counted as wrapped display rows)
-- * clamps between prompt_height and prompt_max_height
-- * disables on manual :resize (current_height != expected)
-- * re-enables when the user empties the prompt
-- * toggle/reset behave as documented
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

--- Build a minimal harness inside the child: a Prompt, a window showing it,
--- and an `inst` table with the fields autosize.lua reads. Stored in globals
--- _G._inst, _G._winid, _G._bufnr, _G._prompt for later assertions.
---@param child table
---@param opts table? { prompt_height?, prompt_max_height?, win_width?, win_height? }
local function setup_harness(child, opts)
  opts = opts or {}
  child.lua(string.format([==[
    local Prompt = require('cc.prompt')
    local Config = require('cc.config')
    Config.setup({
      prompt_height = %d,
      prompt_max_height = %d,
    })
    -- Force a deterministic UI size so window widths are predictable.
    vim.o.lines = 50
    vim.o.columns = %d
    -- Single window, take the prompt buffer.
    local prompt = Prompt.new('cc-test-prompt')
    local bufnr = prompt:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    local winid = vim.api.nvim_get_current_win()
    -- Set initial height to default.
    vim.api.nvim_win_set_height(winid, %d)
    local inst = {
      prompt = prompt,
      prompt_winid = winid,
      autosize_disabled = false,
      expected_prompt_height = %d,
    }
    require('cc.autosize').attach(inst)
    _G._inst = inst
    _G._winid = winid
    _G._bufnr = bufnr
    _G._prompt = prompt
  ]==],
    opts.prompt_height or 10,
    opts.prompt_max_height or 30,
    opts.win_width or 80,
    opts.prompt_height or 10,
    opts.prompt_height or 10
  ))
end

local function set_buf(child, lines)
  child.lua(string.format(
    'vim.api.nvim_buf_set_lines(_G._bufnr, 0, -1, false, %s)',
    vim.inspect(lines)))
end

local function win_height(child)
  return child.lua_get('vim.api.nvim_win_get_height(_G._winid)')
end

local function autosize_disabled(child)
  return child.lua_get('_G._inst.autosize_disabled')
end

local function expected_height(child)
  return child.lua_get('_G._inst.expected_prompt_height')
end

-- ---------------------------------------------------------------------------
-- resize: clamping to [prompt_height, prompt_max_height]
-- ---------------------------------------------------------------------------
T['resize'] = MiniTest.new_set()

T['resize']['short content stays at default height'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  set_buf(_G.child, { 'one line' })
  _G.child.lua("require('cc.autosize').resize(_G._inst)")
  eq(win_height(_G.child), 10)
  eq(expected_height(_G.child), 10)
end

T['resize']['grows past default for many short lines'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  local lines = {}
  for i = 1, 15 do table.insert(lines, 'line ' .. i) end
  set_buf(_G.child, lines)
  _G.child.lua("require('cc.autosize').resize(_G._inst)")
  eq(win_height(_G.child), 15)
  eq(expected_height(_G.child), 15)
end

T['resize']['clamps at prompt_max_height'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 20 })
  local lines = {}
  for i = 1, 50 do table.insert(lines, 'line ' .. i) end
  set_buf(_G.child, lines)
  _G.child.lua("require('cc.autosize').resize(_G._inst)")
  eq(win_height(_G.child), 20)
  eq(expected_height(_G.child), 20)
end

T['resize']['counts wrapped display rows for long lines'] = function()
  -- Window width is 80; a single 200-char line wraps to ceil(200/80)=3 rows.
  -- One such line plus the implicit minimum should give 3, but 3 < default
  -- so we expect the default (10).
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30, win_width = 80 })
  set_buf(_G.child, { string.rep('x', 200) })
  _G.child.lua("require('cc.autosize').resize(_G._inst)")
  eq(win_height(_G.child), 10)

  -- Five 200-char lines = 15 wrapped rows -> grow past default.
  local long = string.rep('x', 200)
  set_buf(_G.child, { long, long, long, long, long })
  _G.child.lua("require('cc.autosize').resize(_G._inst)")
  eq(win_height(_G.child), 15)
end

T['resize']['no-op when autosize_disabled is set'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  -- Pre-shrink the window so we can prove resize() doesn't touch it.
  _G.child.lua('vim.api.nvim_win_set_height(_G._winid, 7)')
  _G.child.lua('_G._inst.autosize_disabled = true')
  local lines = {}
  for i = 1, 20 do table.insert(lines, 'line ' .. i) end
  set_buf(_G.child, lines)
  _G.child.lua("require('cc.autosize').resize(_G._inst)")
  eq(win_height(_G.child), 7)
end

-- ---------------------------------------------------------------------------
-- TextChanged autocmd: drives resize as content changes.
-- ---------------------------------------------------------------------------
T['textchanged'] = MiniTest.new_set()

T['textchanged']['fires resize on TextChanged'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  local lines = {}
  for i = 1, 18 do table.insert(lines, 'line ' .. i) end
  set_buf(_G.child, lines)
  -- nvim_buf_set_lines does not fire TextChanged; trigger it explicitly
  -- to simulate the user typing/pasting.
  _G.child.lua("vim.api.nvim_exec_autocmds('TextChanged', { buffer = _G._bufnr })")
  eq(win_height(_G.child), 18)
end

-- ---------------------------------------------------------------------------
-- Manual :resize disables autosize via the WinResized handler.
-- ---------------------------------------------------------------------------
T['winresized'] = MiniTest.new_set()

T['winresized']['external resize flips autosize_disabled'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  -- Simulate `:resize 7` — actual height (7) now differs from
  -- expected_prompt_height (10). The handler should flip the disable flag
  -- and snap expected to the new current so we don't repeatedly flag.
  _G.child.lua([[
    vim.api.nvim_win_set_height(_G._winid, 7)
    require('cc.autosize')._handle_winresized(_G._inst, { _G._winid })
  ]])
  eq(autosize_disabled(_G.child), true)
  eq(expected_height(_G.child), 7)
end

T['winresized']['programmatic resize does NOT disable autosize'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  -- resize() updates expected_prompt_height before changing the window
  -- height, so a follow-up WinResized sees current==expected and bails.
  local lines = {}
  for i = 1, 18 do table.insert(lines, 'line ' .. i) end
  set_buf(_G.child, lines)
  _G.child.lua([[
    require('cc.autosize').resize(_G._inst)
    require('cc.autosize')._handle_winresized(_G._inst, { _G._winid })
  ]])
  eq(autosize_disabled(_G.child), false)
  eq(win_height(_G.child), 18)
end

T['winresized']['ignores resize events for other windows'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  -- Open a split (which fires a real WinResized through attach()'s autocmd
  -- because the prompt window's actual height changes). Reset state so we
  -- can isolate the "resized list does not contain the prompt" code path.
  _G.child.lua([[
    vim.cmd('aboveleft split')
    _G._other_win = vim.api.nvim_get_current_win()
    assert(_G._other_win ~= _G._winid)
    _G._inst.autosize_disabled = false
    _G._inst.expected_prompt_height = vim.api.nvim_win_get_height(_G._winid)
    require('cc.autosize')._handle_winresized(_G._inst, { _G._other_win })
  ]])
  eq(autosize_disabled(_G.child), false)
end

-- ---------------------------------------------------------------------------
-- Re-enable on manual buffer empty.
-- ---------------------------------------------------------------------------
T['empty_reenable'] = MiniTest.new_set()

T['empty_reenable']['emptying the buffer re-enables autosize'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  -- Disable autosize directly (simulating an earlier manual :resize).
  _G.child.lua('_G._inst.autosize_disabled = true')
  -- User deletes everything: buffer becomes a single empty line.
  set_buf(_G.child, { '' })
  _G.child.lua("vim.api.nvim_exec_autocmds('TextChanged', { buffer = _G._bufnr })")
  eq(autosize_disabled(_G.child), false)
end

T['empty_reenable']['whitespace-only buffer counts as empty'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  _G.child.lua('_G._inst.autosize_disabled = true')
  set_buf(_G.child, { '   ', '\t', '' })
  _G.child.lua("vim.api.nvim_exec_autocmds('TextChanged', { buffer = _G._bufnr })")
  eq(autosize_disabled(_G.child), false)
end

T['empty_reenable']['non-empty buffer does NOT re-enable'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  _G.child.lua('_G._inst.autosize_disabled = true')
  set_buf(_G.child, { 'still typing here' })
  _G.child.lua("vim.api.nvim_exec_autocmds('TextChanged', { buffer = _G._bufnr })")
  eq(autosize_disabled(_G.child), true)
end

T['empty_reenable']['re-enable then resize collapses back to default'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  -- Start with a tall buffer at default size, autosize disabled, and a
  -- manually-shrunken window.
  local lines = {}
  for i = 1, 18 do table.insert(lines, 'line ' .. i) end
  set_buf(_G.child, lines)
  _G.child.lua([[
    _G._inst.autosize_disabled = true
    vim.api.nvim_win_set_height(_G._winid, 5)
  ]])
  -- User deletes everything.
  set_buf(_G.child, { '' })
  _G.child.lua("vim.api.nvim_exec_autocmds('TextChanged', { buffer = _G._bufnr })")
  eq(autosize_disabled(_G.child), false)
  eq(win_height(_G.child), 10)
end

-- ---------------------------------------------------------------------------
-- toggle / reset
-- ---------------------------------------------------------------------------
T['toggle'] = MiniTest.new_set()

T['toggle']['nil arg flips state'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  eq(autosize_disabled(_G.child), false)
  local enabled = _G.child.lua_get("require('cc.autosize').toggle(_G._inst)")
  eq(enabled, false)
  eq(autosize_disabled(_G.child), true)
  enabled = _G.child.lua_get("require('cc.autosize').toggle(_G._inst)")
  eq(enabled, true)
  eq(autosize_disabled(_G.child), false)
end

T['toggle']["'on' explicitly enables"] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  _G.child.lua('_G._inst.autosize_disabled = true')
  local enabled = _G.child.lua_get("require('cc.autosize').toggle(_G._inst, 'on')")
  eq(enabled, true)
  eq(autosize_disabled(_G.child), false)
end

T['toggle']["'off' explicitly disables"] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  local enabled = _G.child.lua_get("require('cc.autosize').toggle(_G._inst, 'off')")
  eq(enabled, false)
  eq(autosize_disabled(_G.child), true)
end

T['toggle']['toggling on resizes to fit content'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  -- Disable, fill with content, manually shrink window, then toggle back on.
  local lines = {}
  for i = 1, 16 do table.insert(lines, 'line ' .. i) end
  set_buf(_G.child, lines)
  _G.child.lua([[
    _G._inst.autosize_disabled = true
    vim.api.nvim_win_set_height(_G._winid, 5)
  ]])
  _G.child.lua("require('cc.autosize').toggle(_G._inst, 'on')")
  eq(win_height(_G.child), 16)
end

T['reset'] = MiniTest.new_set()

T['reset']['clears disabled flag and resizes'] = function()
  setup_harness(_G.child, { prompt_height = 10, prompt_max_height = 30 })
  _G.child.lua([[
    _G._inst.autosize_disabled = true
    vim.api.nvim_win_set_height(_G._winid, 5)
  ]])
  set_buf(_G.child, { 'short' })
  _G.child.lua("require('cc.autosize').reset(_G._inst)")
  eq(autosize_disabled(_G.child), false)
  eq(win_height(_G.child), 10)
end

return T
