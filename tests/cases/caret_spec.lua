-- Tests for caret extmark sync: ▾ (open) / ▸ (folded) on fold headers.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

-- ---------------------------------------------------------------------------
-- Resume path (JSONL)
-- ---------------------------------------------------------------------------
T['resume_path'] = MiniTest.new_set()

T['resume_path']['user header gets a caret extmark'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  -- At least one caret should exist
  eq(#marks > 0, true)
end

T['resume_path']['caret appears on fold header lines'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  -- Fold headers are tracked in buf_state; carets should be on those lines
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  local fold_levels = helpers.get_fold_levels(_G.child)
  local header_rows = {}
  for lnum, fl in pairs(fold_levels) do
    if type(fl) == 'string' and fl:match('^>') then
      header_rows[lnum - 1] = true -- extmarks use 0-indexed rows
    end
  end
  -- Every caret should be on a header line
  for _, mark in ipairs(marks) do
    eq(header_rows[mark.row] ~= nil, true)
  end
end

T['resume_path']['caret has CcCaret highlight'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  eq(#marks > 0, true)
  for _, mark in ipairs(marks) do
    local vt = mark.details.virt_text
    eq(vt ~= nil, true)
    eq(#vt > 0, true)
    eq(vt[1][2], 'CcCaret')
  end
end

T['resume_path']['multi_turn has carets on user, agent, and tool headers'] = function()
  helpers.render_fixture(_G.child, 'multi_turn')
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  -- multi_turn has multiple turns and tools, should have several carets
  eq(#marks >= 3, true)
end

-- ---------------------------------------------------------------------------
-- Streaming path (NDJSON)
-- ---------------------------------------------------------------------------
T['streaming_path'] = MiniTest.new_set()

T['streaming_path']['agent header gets caret'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  eq(#marks > 0, true)
end

T['streaming_path']['tool headers get carets'] = function()
  helpers.replay_streaming(_G.child, 'tool_bash')
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  -- Should have carets for agent header and tool header at minimum
  eq(#marks >= 2, true)
end

T['streaming_path']['multi_block gets carets for all headers'] = function()
  helpers.replay_streaming(_G.child, 'multi_block')
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  -- multi_block: agent header + Read tool + Bash tool + Output headers
  eq(#marks >= 3, true)
end

T['streaming_path']['caret text is valid fold character'] = function()
  helpers.replay_streaming(_G.child, 'simple_text')
  local marks = helpers.get_extmarks(_G.child, 'cc.carets')
  for _, mark in ipairs(marks) do
    local vt = mark.details.virt_text
    local char = vt[1][1]:gsub('%s', '') -- strip spaces
    local valid = char == '▾' or char == '▸'
    eq(valid, true)
  end
end

return T
