-- E2E test: cc.nvim's window-local options must not leak into windows that
-- subsequently display non-cc buffers (e.g. when the user `:edit`s a code
-- file from the prompt window).
--
-- cc.nvim deliberately disables `number`, `relativenumber`, and forces a
-- particular `wrap` value on its prompt and output windows (see
-- prompt.lua:_setup_window_opts_for_buffer and output.lua likewise). Those
-- are window-local options, so when the user runs `:edit foo.lua` from the
-- prompt window the buffer changes but the window-local values persist —
-- and the user's foo.lua loads with line numbers off, etc.

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      _G.child = nil
    end,
    post_case = function()
      if _G.child then
        pcall(function() _G.child:close() end)
        _G.child = nil
      end
    end,
  },
})

T['cc_window_options_do_not_leak_into_other_files'] = function()
  _G.child = h.spawn({ lines = 40, columns = 100 })

  -- Configure user defaults that DIFFER from cc.nvim's window settings.
  -- cc.nvim turns number/relativenumber OFF and wrap ON; the user has
  -- the opposite preferences here.
  _G.child:lua([[
    vim.o.number = true
    vim.o.relativenumber = true
    vim.o.signcolumn = 'yes'
    vim.o.wrap = false
  ]])

  -- Open a cc.nvim session via the fake-claude fixture (this is what
  -- :CcNew does under the hood — spawn the prompt+output windows and
  -- run the BufWinEnter setup that applies cc's window-local options).
  h.open_with_fixture(_G.child, 'simple_text')

  if not h.wait_for_session_end(_G.child, 8000) then
    error('session did not end. ' .. h.dump_viewport(_G.child, _G.child:find_winid_for_buf('cc-output')))
  end
  _G.child:sleep(150)

  -- From the prompt window (current after :CcNew), open a regular code
  -- file. This swaps the prompt buffer out for a non-cc buffer in the
  -- SAME window — the leak surface.
  local prompt_winid = _G.child:find_winid_for_buf('cc-nvim')
  if not prompt_winid then error('no prompt window') end

  _G.child:lua(
    [[
    local prompt_winid = ...
    vim.api.nvim_set_current_win(prompt_winid)
    -- pcall around :edit because in --clean mode Neovim's bundled lua
    -- ftplugin tries to start a treesitter parser that isn't installed,
    -- which raises in the FileType autocmd. The buffer still loads — we
    -- just want the side effect of opening it in this window.
    pcall(vim.cmd, 'edit plugin/cc.lua')
  ]],
    { prompt_winid }
  )
  _G.child:sleep(100)

  local opts = _G.child:lua([[
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(winid)
    return {
      buf_name = vim.api.nvim_buf_get_name(bufnr),
      number = vim.wo[winid].number,
      relativenumber = vim.wo[winid].relativenumber,
      signcolumn = vim.wo[winid].signcolumn,
      wrap = vim.wo[winid].wrap,
    }
  ]])

  if not opts.buf_name:match('plugin/cc%.lua$') then
    error('expected plugin/cc.lua to be loaded, got: ' .. tostring(opts.buf_name))
  end

  local fail = {}
  if opts.number ~= true then
    table.insert(fail, string.format('number: expected true, got %s', tostring(opts.number)))
  end
  if opts.relativenumber ~= true then
    table.insert(fail, string.format('relativenumber: expected true, got %s', tostring(opts.relativenumber)))
  end
  if opts.signcolumn ~= 'yes' then
    table.insert(fail, string.format('signcolumn: expected "yes", got %q', tostring(opts.signcolumn)))
  end
  if opts.wrap ~= false then
    table.insert(fail, string.format('wrap: expected false, got %s', tostring(opts.wrap)))
  end

  if #fail > 0 then
    error('cc.nvim window options leaked into ' .. opts.buf_name .. ':\n  ' ..
      table.concat(fail, '\n  '))
  end
end

return T
