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
---@field streaming_idx integer? index into the parser's regions list of the
---  currently in-flight streaming region (set by begin_streaming, cleared
---  by end_streaming). The list order is stable across edits — on_bytes
---  shifts ranges within regions but does not reorder regions — so the
---  index stays valid unless before_delete_row drops an earlier region,
---  and that function re-points it.
---@field batch cc.MdHl.Batch? open replay batch (begin_batch .. end_batch)

---@class cc.MdHl.Batch
---@field entries { start_id: integer, end_id: integer? }[] pending ranges in
---  registration order; extmarks keep their rows aligned through buffer edits
---@field streaming integer? index into entries of the in-flight streaming range

---@type table<integer, cc.MdHl.State>
local buf_state = {}

-- A parser with no included_regions parses the whole buffer; we want it
-- to parse nothing until a real range is registered. Pass this zero-byte
-- range whenever the live region list would otherwise be empty.
local VOID_REGIONS = { { { 0, 0, 0, 0 } } }

-- Batched ranges are tracked with extmarks until end_batch hands them to
-- the parser in one set_included_regions + parse.
local BATCH_NS = vim.api.nvim_create_namespace('cc.md_highlight.batch')

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

---@param bufnr integer
---@param entry { start_id: integer, end_id: integer? }
---@param row integer 0-indexed
---@param col integer
local function batch_set_end(bufnr, entry, row, col)
  -- Left gravity on the end and right on the start match how tree-sitter
  -- shifts an included range when text lands exactly on its boundary.
  entry.end_id = vim.api.nvim_buf_set_extmark(bufnr, BATCH_NS, row, col,
    { id = entry.end_id, right_gravity = false })
end

--- Track a range in the open batch. Returns its index in batch.entries.
---@return integer
local function batch_add(bufnr, batch, start_row, end_row, end_col)
  local entry = { start_id = vim.api.nvim_buf_set_extmark(bufnr, BATCH_NS, start_row, 0, {}) }
  batch_set_end(bufnr, entry, end_row, end_col)
  batch.entries[#batch.entries + 1] = entry
  return #batch.entries
end

--- Batch counterpart of before_delete_row's region fix-up: a range ending on
--- `row` is cut back to the row above, one living only on `row` is dropped.
local function batch_before_delete_row(bufnr, batch, row)
  local kept, streaming = {}, nil
  for i, entry in ipairs(batch.entries) do
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, BATCH_NS, entry.start_id, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, BATCH_NS, entry.end_id, {})
    local keep = true
    if e[1] == row then
      if s[1] < row then
        local prev = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
        batch_set_end(bufnr, entry, row - 1, #prev)
      else
        keep = false
        vim.api.nvim_buf_del_extmark(bufnr, BATCH_NS, entry.start_id)
        vim.api.nvim_buf_del_extmark(bufnr, BATCH_NS, entry.end_id)
      end
    end
    if keep then
      kept[#kept + 1] = entry
      if i == batch.streaming then streaming = #kept end
    end
  end
  batch.entries = kept
  batch.streaming = streaming
end

--- Start deferring region registration for a buffer. Between begin_batch
--- and end_batch, add_range / begin_streaming / update_streaming record
--- ranges as extmarks instead of re-parsing the whole region list on every
--- call, which is quadratic in the number of prose blocks. Used for
--- transcript replay, where nothing is displayed until the end anyway.
---@param bufnr integer
function M.begin_batch(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local state = attach(bufnr)
  if not state or state.batch then return end
  state.batch = { entries = {} }
end

--- Hand every batched range to the parser with one parse. No-op without
--- an open batch.
---@param bufnr integer
function M.end_batch(bufnr)
  local state = buf_state[bufnr]
  local batch = state and state.batch
  if not batch then return end
  state.batch = nil
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local regions = {}
  local current = state.parser:included_regions() or {}
  if not regions_are_void(current) then
    for _, region in ipairs(current) do regions[#regions + 1] = region end
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for i, entry in ipairs(batch.entries) do
    local s = vim.api.nvim_buf_get_extmark_by_id(bufnr, BATCH_NS, entry.start_id, {})
    local e = vim.api.nvim_buf_get_extmark_by_id(bufnr, BATCH_NS, entry.end_id, {})
    if s[1] and e[1] and e[1] < line_count and e[1] >= s[1] then
      -- Only the rows come from the marks. Every range spans whole lines,
      -- and a later setbufline() of a boundary line collapses the marks'
      -- columns, so read the end column from the line as it is now.
      local last_line = vim.api.nvim_buf_get_lines(bufnr, e[1], e[1] + 1, false)[1] or ''
      regions[#regions + 1] = { { s[1], 0, e[1], #last_line } }
      if i == batch.streaming then state.streaming_idx = #regions end
    end
  end
  vim.api.nvim_buf_clear_namespace(bufnr, BATCH_NS, 0, -1)
  if #regions == 0 then return end
  pcall(state.parser.set_included_regions, state.parser, regions)
  pcall(state.parser.parse, state.parser, true)
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
  if state.batch then
    batch_add(bufnr, state.batch, start_lnum - 1, end_lnum - 1, #last_line)
    return
  end
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

--- Begin tracking an in-flight streaming markdown range. Appends a 1-line
--- region for the start line and records its index so subsequent
--- update_streaming calls can extend it as the block grows.
---@param bufnr integer
---@param start_lnum integer 1-indexed first line of the streaming block
function M.begin_streaming(bufnr, start_lnum)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local state = attach(bufnr)
  if not state then return end

  local last_line = vim.api.nvim_buf_get_lines(bufnr, start_lnum - 1, start_lnum, false)[1] or ''
  if state.batch then
    state.batch.streaming =
      batch_add(bufnr, state.batch, start_lnum - 1, start_lnum - 1, #last_line)
    return
  end
  local new_region = { { start_lnum - 1, 0, start_lnum - 1, #last_line } }

  local current = state.parser:included_regions() or {}
  local regions = {}
  if not regions_are_void(current) then
    for _, region in ipairs(current) do
      table.insert(regions, region)
    end
  end
  table.insert(regions, new_region)
  state.streaming_idx = #regions
  pcall(state.parser.set_included_regions, state.parser, regions)
  pcall(state.parser.parse, state.parser, true)
end

--- Extend the in-flight streaming region's end to (end_lnum, end of line).
--- No-op if begin_streaming wasn't called.
---@param bufnr integer
---@param end_lnum integer 1-indexed last line currently belonging to the block
function M.update_streaming(bufnr, end_lnum)
  local state = buf_state[bufnr]
  if not state then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if state.batch then
    local entry = state.batch.entries[state.batch.streaming or 0]
    if not entry then return end
    local start_row = vim.api.nvim_buf_get_extmark_by_id(bufnr, BATCH_NS, entry.start_id, {})[1]
    local end_row = end_lnum - 1
    if not start_row or end_row < start_row then return end
    local last_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ''
    batch_set_end(bufnr, entry, end_row, #last_line)
    return
  end
  if not state.streaming_idx then return end

  -- LanguageTree:included_regions() returns the parser's internal _regions
  -- table by reference, NOT a copy. Mutating it directly (e.g. assigning to
  -- current[idx]) updates the parser's state in place. set_included_regions
  -- then sees no change vs its own internal table and skips invalidation —
  -- so the markdown_inline child injection is never refreshed and bold/
  -- italic etc. never appear during streaming. Deep-copying first means the
  -- value passed to set_included_regions is a distinct table whose
  -- streaming entry differs from the parser's stored copy, which correctly
  -- triggers _iter_regions to invalidate the entry and re-run injections
  -- against the freshly-parsed tree.
  local current = state.parser:included_regions() or {}
  if state.streaming_idx > #current then return end

  local source_region = current[state.streaming_idx]
  if not source_region or #source_region == 0 then return end
  local first_range = source_region[1]
  local start_row, start_col = first_range[1], first_range[2]

  local last_line = vim.api.nvim_buf_get_lines(bufnr, end_lnum - 1, end_lnum, false)[1] or ''
  local end_row = end_lnum - 1
  if end_row < start_row then return end

  local fresh = vim.deepcopy(current)
  fresh[state.streaming_idx] = { { start_row, start_col, end_row, #last_line } }
  pcall(state.parser.set_included_regions, state.parser, fresh)
  pcall(state.parser.parse, state.parser, true)
end

--- Stop tracking the in-flight streaming region. The region itself is left
--- in place so its highlighting persists; only the index is cleared.
---@param bufnr integer
function M.end_streaming(bufnr)
  local state = buf_state[bufnr]
  if not state then return end
  state.streaming_idx = nil
  if state.batch then state.batch.streaming = nil end
end

--- Shorten or drop the regions that end on buffer row `row` (0-indexed),
--- which the caller is about to delete. Tree-sitter clamps a range end that
--- falls inside a deleted span to the span's start byte. If the row is the
--- buffer's last line, that byte is the new EOF, and every later append at
--- EOF drags the range end along with it: the region swallows every tool
--- rendered afterwards, and their indented bodies parse as markdown code.
--- A region ending on the row is cut back to the end of the row above; one
--- that lives only on the row is dropped. Tree-sitter's own edit handling is
--- correct for every other region.
---@param bufnr integer
---@param row integer 0-indexed row about to be deleted
function M.before_delete_row(bufnr, row)
  local state = buf_state[bufnr]
  if not state then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  if state.batch then batch_before_delete_row(bufnr, state.batch, row) end

  local current = state.parser:included_regions() or {}
  if regions_are_void(current) then return end

  -- Ranges read back from the parser are Range6:
  -- { start_row, start_col, start_byte, end_row, end_col, end_byte }.
  local fresh = {}
  local streaming_idx
  local changed = false
  for i, region in ipairs(current) do
    local r = region[1]
    local kept = region
    if #region == 1 and r[4] == row then
      changed = true
      if r[1] < row then
        local prev = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
        kept = { { r[1], r[2], row - 1, #prev } }
      else
        kept = nil
      end
    end
    if kept then
      fresh[#fresh + 1] = kept
      if i == state.streaming_idx then streaming_idx = #fresh end
    end
  end
  if not changed then return end

  -- Dropping a region shifts every later index, including the streaming one.
  state.streaming_idx = streaming_idx
  if #fresh == 0 then fresh = vim.deepcopy(VOID_REGIONS) end
  pcall(state.parser.set_included_regions, state.parser, fresh)
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
