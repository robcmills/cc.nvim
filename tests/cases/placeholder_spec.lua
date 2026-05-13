-- Tests for the prompt placeholder module:
-- * shown when buffer is empty, hidden when non-empty
-- * cleared by user typing (TextChanged / TextChangedI)
-- * re-rendered when Prompt:clear() empties the buffer
-- * customizable via config.prompt_placeholder
-- * disabled when config.prompt_placeholder is false / ''
-- * uses CcPromptPlaceholder highlight group
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Build a Prompt + window in the child, attach the placeholder module, and
--- stash references in globals (_G._bufnr, _G._winid).
---@param child table
---@param opts table? { prompt_placeholder? }
local function setup_harness(child, opts)
  opts = opts or {}
  local cfg = vim.inspect({ prompt_placeholder = opts.prompt_placeholder })
  child.lua(string.format([==[
    local Prompt = require('cc.prompt')
    local Config = require('cc.config')
    local opts = %s
    -- Drop the default so absence of `prompt_placeholder` means "default".
    if opts.prompt_placeholder == nil then opts.prompt_placeholder = nil end
    Config.setup(opts)
    local prompt = Prompt.new('cc-test-placeholder')
    local bufnr = prompt:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    require('cc.placeholder').attach(bufnr)
    _G._prompt = prompt
    _G._bufnr = bufnr
    _G._winid = vim.api.nvim_get_current_win()
  ]==], cfg))
end

--- Return the placeholder extmark spec on line 0 of the prompt buffer.
--- nil when no placeholder is rendered.
local function get_placeholder(child)
  child.lua([==[
    local ns = vim.api.nvim_get_namespaces()['cc.placeholder']
    if not ns then _G._mark = nil; return end
    local marks = vim.api.nvim_buf_get_extmarks(_G._bufnr, ns, 0, -1, { details = true })
    if #marks == 0 then _G._mark = nil; return end
    local m = marks[1]
    _G._mark = { row = m[2], col = m[3], details = m[4] }
  ]==])
  return child.lua_get('_G._mark')
end

local function set_buf(child, lines)
  child.lua(string.format(
    'vim.api.nvim_buf_set_lines(_G._bufnr, 0, -1, false, %s)',
    vim.inspect(lines)))
end

local function fire_textchanged(child)
  child.lua([[vim.api.nvim_exec_autocmds('TextChanged', { buffer = _G._bufnr })]])
end

-- ---------------------------------------------------------------------------
-- Default behavior
-- ---------------------------------------------------------------------------
T['default'] = MiniTest.new_set()

T['default']['placeholder appears on empty buffer'] = function()
  setup_harness(_G.child)
  local mark = get_placeholder(_G.child)
  eq(mark ~= nil, true)
  eq(mark.row, 0)
  local vt = mark.details.virt_text
  eq(vt[1][1], 'Write prompt here. Press <Enter> in normal mode to submit.')
  eq(vt[1][2], 'CcPromptPlaceholder')
end

T['default']['placeholder disappears when buffer has content'] = function()
  setup_harness(_G.child)
  set_buf(_G.child, { 'hello' })
  fire_textchanged(_G.child)
  eq(get_placeholder(_G.child), vim.NIL)
end

T['default']['placeholder reappears after Prompt:clear()'] = function()
  setup_harness(_G.child)
  set_buf(_G.child, { 'hello' })
  fire_textchanged(_G.child)
  eq(get_placeholder(_G.child), vim.NIL)
  _G.child.lua('_G._prompt:clear()')
  local mark = get_placeholder(_G.child)
  eq(mark ~= nil, true)
end

T['default']['placeholder reappears when user empties the buffer'] = function()
  setup_harness(_G.child)
  set_buf(_G.child, { 'typing' })
  fire_textchanged(_G.child)
  eq(get_placeholder(_G.child), vim.NIL)
  set_buf(_G.child, { '' })
  fire_textchanged(_G.child)
  eq(get_placeholder(_G.child) ~= nil, true)
end

T['default']['multi-line content hides placeholder'] = function()
  setup_harness(_G.child)
  set_buf(_G.child, { '', '' })
  fire_textchanged(_G.child)
  -- Two empty lines is not "empty" per the strict single-empty-line rule.
  eq(get_placeholder(_G.child), vim.NIL)
end

-- ---------------------------------------------------------------------------
-- Customization
-- ---------------------------------------------------------------------------
T['custom'] = MiniTest.new_set()

T['custom']['custom text via config'] = function()
  setup_harness(_G.child, { prompt_placeholder = 'Type something cool' })
  local mark = get_placeholder(_G.child)
  eq(mark ~= nil, true)
  eq(mark.details.virt_text[1][1], 'Type something cool')
end

T['custom']['false disables placeholder'] = function()
  setup_harness(_G.child, { prompt_placeholder = false })
  eq(get_placeholder(_G.child), vim.NIL)
end

T['custom']['empty string disables placeholder'] = function()
  setup_harness(_G.child, { prompt_placeholder = '' })
  eq(get_placeholder(_G.child), vim.NIL)
end

-- ---------------------------------------------------------------------------
-- Highlight group
-- ---------------------------------------------------------------------------
T['highlight'] = MiniTest.new_set()

T['highlight']['CcPromptPlaceholder is defined and links to Comment'] = function()
  setup_harness(_G.child)
  _G.child.lua([==[
    require('cc.highlight').set_defaults()
    local hl = vim.api.nvim_get_hl(0, { name = 'CcPromptPlaceholder' })
    _G._hl = hl
  ]==])
  local hl = _G.child.lua_get('_G._hl')
  -- Either link='Comment' (default) or a direct spec — both count as defined.
  eq(hl ~= nil and next(hl) ~= nil, true)
  eq(hl.link, 'Comment')
end

-- ---------------------------------------------------------------------------
-- Detach
-- ---------------------------------------------------------------------------
T['detach'] = MiniTest.new_set()

T['detach']['detach removes the extmark and stops responding to changes'] = function()
  setup_harness(_G.child)
  eq(get_placeholder(_G.child) ~= nil, true)
  _G.child.lua("require('cc.placeholder').detach(_G._bufnr)")
  eq(get_placeholder(_G.child), vim.NIL)
  -- Subsequent TextChanged should not re-create the extmark.
  set_buf(_G.child, { '' })
  fire_textchanged(_G.child)
  eq(get_placeholder(_G.child), vim.NIL)
end

return T
