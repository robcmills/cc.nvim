-- The output window's cursor follows the streaming line, and a paragraph is
-- one wrapped buffer line, so a user's global 'cursorline' painted each
-- paragraph as a block while it streamed. cc turns it off in the output
-- window unless config.cursorline.output is set, and then highlights only
-- the cursor's screen row.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function load(opts)
  _G.child.lua(([[
    vim.o.cursorline = true
    vim.o.cursorlineopt = 'both'
    require('cc.config').setup(%s)
    require('cc').load_fixture('simple_text')
    local winid = require('cc')._get_instance().output_winid
    _G._cul = { vim.wo[winid].cursorline, vim.wo[winid].cursorlineopt }
  ]]):format(vim.inspect(opts)))
  return _G.child.lua_get('_G._cul')
end

T['off in the output window by default, despite a global cursorline'] = function()
  eq(load({}), { false, 'both' })
end

T['config.cursorline.output highlights the screen row only'] = function()
  eq(load({ cursorline = { output = true } }), { true, 'number,screenline' })
end

T["replacing the output buffer restores the user's values"] = function()
  load({ cursorline = { output = true } })
  _G.child.lua([[
    local winid = require('cc')._get_instance().output_winid
    vim.api.nvim_set_current_win(winid)
    pcall(vim.cmd, 'edit plugin/cc.lua')
    _G._cul = { vim.wo[winid].cursorline, vim.wo[winid].cursorlineopt }
  ]])
  eq(_G.child.lua_get('_G._cul'), { true, 'both' })
end

return T
