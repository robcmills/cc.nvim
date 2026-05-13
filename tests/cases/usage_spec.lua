-- Tests for cc.usage: normalize() and fmt_compact() — the canonical helpers
-- used by session.lua, history.lua, cost.lua, and statusline.lua to talk
-- about token usage in one shape.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['normalize'] = MiniTest.new_set()

T['normalize']['nil returns zero struct'] = function()
  _G.child.lua([[_G._u = require('cc.usage').normalize(nil)]])
  eq(_G.child.lua_get('_G._u.input'), 0)
  eq(_G.child.lua_get('_G._u.output'), 0)
  eq(_G.child.lua_get('_G._u.cache_creation'), 0)
  eq(_G.child.lua_get('_G._u.cache_read'), 0)
  eq(_G.child.lua_get('_G._u.context_size'), 0)
  eq(_G.child.lua_get('_G._u.total'), 0)
end

T['normalize']['non-table returns zero struct'] = function()
  _G.child.lua([[_G._u = require('cc.usage').normalize('nope')]])
  eq(_G.child.lua_get('_G._u.context_size'), 0)
end

T['normalize']['extracts API field names'] = function()
  _G.child.lua([[
    _G._u = require('cc.usage').normalize({
      input_tokens = 100,
      output_tokens = 50,
      cache_creation_input_tokens = 2000,
      cache_read_input_tokens = 10000,
    })
  ]])
  eq(_G.child.lua_get('_G._u.input'), 100)
  eq(_G.child.lua_get('_G._u.output'), 50)
  eq(_G.child.lua_get('_G._u.cache_creation'), 2000)
  eq(_G.child.lua_get('_G._u.cache_read'), 10000)
end

T['normalize']['context_size = input + cache_creation + cache_read'] = function()
  _G.child.lua([[
    _G._u = require('cc.usage').normalize({
      input_tokens = 100,
      cache_creation_input_tokens = 2000,
      cache_read_input_tokens = 10000,
    })
  ]])
  -- Right denominator for "% of context window": the size of the prompt the
  -- API request actually sent (whether new, cache-write, or cache-read).
  eq(_G.child.lua_get('_G._u.context_size'), 12100)
end

T['normalize']['total = input + output (excludes cache)'] = function()
  -- Billing-style total. Cache values are billed at different rates and
  -- comparing them to fresh tokens 1:1 is meaningless.
  _G.child.lua([[
    _G._u = require('cc.usage').normalize({
      input_tokens = 100,
      output_tokens = 50,
      cache_creation_input_tokens = 9999,
      cache_read_input_tokens = 9999,
    })
  ]])
  eq(_G.child.lua_get('_G._u.total'), 150)
end

T['normalize']['missing fields default to 0'] = function()
  _G.child.lua([[
    _G._u = require('cc.usage').normalize({ input_tokens = 5 })
  ]])
  eq(_G.child.lua_get('_G._u.output'), 0)
  eq(_G.child.lua_get('_G._u.cache_read'), 0)
  eq(_G.child.lua_get('_G._u.context_size'), 5)
end

T['fmt_compact'] = MiniTest.new_set()

T['fmt_compact']['nil returns empty'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(nil)]])
  eq(_G.child.lua_get('_G._v'), '')
end

T['fmt_compact']['zero returns empty'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(0)]])
  eq(_G.child.lua_get('_G._v'), '')
end

T['fmt_compact']['negative returns empty'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(-1)]])
  eq(_G.child.lua_get('_G._v'), '')
end

T['fmt_compact']['under 1000 plain integer'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(42)]])
  eq(_G.child.lua_get('_G._v'), '42')
end

T['fmt_compact']['exactly 999'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(999)]])
  eq(_G.child.lua_get('_G._v'), '999')
end

T['fmt_compact']['1500 → 1.5k'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(1500)]])
  eq(_G.child.lua_get('_G._v'), '1.5k')
end

T['fmt_compact']['strips trailing .0'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(2000)]])
  eq(_G.child.lua_get('_G._v'), '2k')
end

T['fmt_compact']['large value: 154900 → 154.9k'] = function()
  _G.child.lua([[_G._v = require('cc.usage').fmt_compact(154900)]])
  eq(_G.child.lua_get('_G._v'), '154.9k')
end

return T
