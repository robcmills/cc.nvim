-- Markdown regions must stay on the prose they were registered for.
--
-- A thinking block whose text ends in "\n\n" leaves a blank line at the
-- buffer tail. The next tool call absorbs the turn into its tool group and
-- deletes that blank. Tree-sitter clamps a range whose end falls inside a
-- deleted row to the start of that row; for the buffer's last row that is
-- the EOF byte, and every later append at EOF then extends the range. Tool
-- bodies below the thinking line got parsed as markdown indented code.
-- Deleted empty "∴ Thinking..." lines left zero-width phantom regions the
-- same way.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

-- Regions as "srow:scol-erow:ecol" strings, zero-width ones, and ones whose
-- end sits on the EOF row.
local function region_report()
  return _G.child.lua([[
    local bufnr = _G._test_bufnr
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local parser = vim.treesitter.highlighter.active[bufnr].tree
    parser:parse(true)
    local all, empty, at_eof = {}, {}, {}
    for _, region in ipairs(parser:included_regions()) do
      local r = region[1]
      local s = string.format('%d:%d-%d:%d', r[1], r[2], r[4], r[5])
      all[#all + 1] = s
      if r[1] == r[4] and r[2] == r[5] then empty[#empty + 1] = s end
      if r[4] >= line_count then at_eof[#at_eof + 1] = s end
    end
    return { all = all, empty = empty, at_eof = at_eof }
  ]])
end

-- Rows `from` through `to` (0-indexed, inclusive) whose first non-blank
-- column carries a markdown `markup.*` capture.
local function markup_rows(from, to)
  return _G.child.lua(string.format([[
    local bufnr = _G._test_bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local rows = {}
    for row = %d, %d do
      local line = lines[row + 1]
      local col = #line:match('^%%s*')
      if col < #line then
        for _, c in ipairs(vim.treesitter.get_captures_at_pos(bufnr, row, col)) do
          if c.capture:match('^markup') then
            rows[#rows + 1] = row .. ':' .. c.capture
          end
        end
      end
    end
    return rows
  ]], from, to))
end

local function find_row(needle)
  return _G.child.lua(string.format([[
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false)) do
      if l:find(%q, 1, true) then return i - 1 end
    end
  ]], needle))
end

T['md regions'] = MiniTest.new_set()

T['md regions']['thinking region stops above the next tool after group absorb'] = function()
  helpers.replay_streaming(_G.child, 'thinking_trailing_blank_group')
  local thinking_row = find_row('Tracking is broken')
  local tool_row = find_row('Bash: Second call')
  eq(type(thinking_row), 'number')
  eq(tool_row, thinking_row + 2)

  -- The region keeps the thinking block's one remaining blank row and ends
  -- there, above the tool header.
  local report = region_report()
  local thinking = vim.tbl_filter(function(s)
    return vim.startswith(s, thinking_row .. ':0-')
  end, report.all)
  eq(thinking, { string.format('%d:0-%d:2', thinking_row, thinking_row + 1) })
  eq(markup_rows(tool_row, find_row('Upgrade fzf') - 1), {})
end

T['md regions']['deleting an empty thinking line leaves no phantom region'] = function()
  helpers.replay_streaming(_G.child, 'thinking_trailing_blank_group')
  eq(region_report().empty, {})
end

T['md regions']['no region is pinned to EOF when the tool output has fences'] = function()
  helpers.replay_streaming(_G.child, 'thinking_tail_delete_fence')
  local report = region_report()
  eq(report.at_eof, {})
  eq(report.empty, {})
  eq(markup_rows(find_row('Bash: Check fzf version'), find_row('Upgrade fzf') - 1), {})
end

return T
