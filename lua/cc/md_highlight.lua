-- Per-buffer, range-scoped markdown tree-sitter highlighting for the
-- cc-output buffer.
--
-- The output buffer's filetype is cc-output, not markdown, so no parser is
-- attached by default. Agent text and thinking blocks register their line
-- ranges here on content_block_stop (and on historical replay), and this
-- module attaches a markdown parser whose included_regions cover only those
-- ranges. The parser auto-adjusts the regions through subsequent buffer
-- edits via on_bytes, so later inserts (e.g. tool_result blocks landing
-- between earlier content) keep the highlight aligned.
--
-- Tool headers, tool input bodies (diffs, code), tool results, and other
-- non-prose content are never inside an included region and so are
-- untouched by the markdown parser. This isolates the buffer from the
-- "markdown_inline ate my code" class of bug (e.g. `~` in `~=` parsed as
-- a strikethrough delimiter).

local M = {}

---@class cc.MdHl.State
---@field parser vim.treesitter.LanguageTree
---@field highlighter vim.treesitter.highlighter

---@type table<integer, cc.MdHl.State>
local buf_state = {}

-- A parser with no included_regions parses the whole buffer; we want it
-- to parse nothing until a real range is registered. Pass this zero-byte
-- range whenever the live region list would otherwise be empty.
local VOID_REGIONS = { { { 0, 0, 0, 0 } } }

local function regions_are_void(regions)
  if #regions ~= 1 then return false end
  local region = regions[1]
  if #region ~= 1 then return false end
  local r = region[1]
  return r[1] == 0 and r[2] == 0 and r[3] == 0 and r[4] == 0
end

local function attach(bufnr)
  local existing = buf_state[bufnr]
  if existing then return existing end

  if not pcall(vim.treesitter.language.add, 'markdown') then return nil end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
  if not ok or not parser then return nil end

  -- Suppress whole-buffer parsing before the highlighter attaches.
  pcall(parser.set_included_regions, parser, VOID_REGIONS)

  -- vim.treesitter.highlighter.new() unconditionally clears the buffer's
  -- 'syntax' option (see highlighter.lua:152), which kills the cc-specific
  -- :syntax match rules (CcUser/CcAgent/CcTool/...) registered earlier.
  -- Save the original option, attach the highlighter, restore the option,
  -- and re-apply the cc syntax matches so legacy syntax keeps working
  -- alongside the TS-driven markdown render on agent prose ranges.
  local saved_syntax = vim.bo[bufnr].syntax

  local hl_ok, highlighter = pcall(vim.treesitter.highlighter.new, parser)
  if not hl_ok or not highlighter then return nil end

  vim.bo[bufnr].syntax = saved_syntax
  pcall(require('cc.highlight').apply_buffer_syntax, bufnr)

  buf_state[bufnr] = { parser = parser, highlighter = highlighter }

  -- Wipe state on buffer destruction so :CcResume of a renamed session
  -- doesn't reuse a stale parser handle (mirrors the cc.output _buf_state
  -- teardown contract from commit ffd9057).
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function() M.cleanup(bufnr) end,
  })

  return buf_state[bufnr]
end

--- Register an agent-prose range to be highlighted as markdown.
---@param bufnr integer
---@param start_lnum integer 1-indexed first line of agent prose
---@param end_lnum integer 1-indexed last line of agent prose (inclusive)
function M.add_range(bufnr, start_lnum, end_lnum)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if end_lnum < start_lnum then return end

  local state = attach(bufnr)
  if not state then return end

  local last_line = vim.api.nvim_buf_get_lines(bufnr, end_lnum - 1, end_lnum, false)[1] or ''
  local new_region = { { start_lnum - 1, 0, end_lnum - 1, #last_line } }

  -- Read the parser's current regions (auto-adjusted by prior buffer edits)
  -- and append the new one. This keeps existing ranges aligned with where
  -- their content actually sits now.
  local current = state.parser:included_regions() or {}
  local regions = {}
  if not regions_are_void(current) then
    for _, region in ipairs(current) do
      table.insert(regions, region)
    end
  end
  table.insert(regions, new_region)
  pcall(state.parser.set_included_regions, state.parser, regions)

  -- Force a parse so the regions get persisted on the tree. LanguageTree
  -- rebuilds self._regions from self._trees on every buffer edit, so
  -- without an immediate parse the regions evaporate at the next
  -- nvim_buf_set_lines.
  pcall(state.parser.parse, state.parser, true)
end

--- Detach parser/highlighter and drop tracked state for a buffer.
---@param bufnr integer
function M.cleanup(bufnr)
  local state = buf_state[bufnr]
  if not state then return end
  if state.highlighter and state.highlighter.destroy then
    pcall(state.highlighter.destroy, state.highlighter)
  end
  buf_state[bufnr] = nil
end

return M
