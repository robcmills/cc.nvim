-- Inline diffs for Edit/MultiEdit/Write tool inputs.
-- Produces line-array output with - / + prefixes and a fold level array.
--
-- Each `*_with_fragments` variant additionally returns reconstructed source
-- fragments suitable for treesitter highlighting:
--   - `after`:  context + added lines, joined as a near-valid post-edit program
--   - `before`: context + removed lines, joined as a near-valid pre-edit program
-- Each fragment carries a `row_map` mapping 0-indexed source rows to 0-indexed
-- indices into `lines`, so callers can translate captures into buffer extmark
-- positions once they know where `lines` was placed in the buffer.

local M = {}

local INDENT = '        '
local DIFF_GLYPH_COL = #INDENT          -- 0-indexed column of +/-/' '/@ glyph
local DIFF_TEXT_COL  = #INDENT + 1      -- 0-indexed column of code after glyph
local WRITE_TEXT_COL = #INDENT + 2      -- "+ "<content>: glyph at 8, space at 9, code at 10

---@param old_text string
---@param new_text string
---@return string[] lines diff lines (with '-'/'+'/' ' prefixes, indented)
function M.unified(old_text, new_text)
  local diff_str = vim.diff(old_text, new_text, {
    result_type = 'unified',
    ctxlen = 2,
    algorithm = 'histogram',
  })
  if type(diff_str) ~= 'string' or diff_str == '' then
    return {}
  end
  local out = {}
  for _, line in ipairs(vim.split(diff_str, '\n', { plain = true })) do
    if line ~= '' then
      -- Skip @@ hunk headers, include them dimmed; skip ---/+++ file headers
      -- since we already show the file path in the tool summary.
      if not (line:sub(1, 3) == '---' or line:sub(1, 3) == '+++') then
        table.insert(out, INDENT .. line)
      end
    end
  end
  return out
end

--- Render a diff between old_string and new_string for Edit-like tools.
---@param old_string string?
---@param new_string string?
---@return string[] lines
function M.render_edit(old_string, new_string)
  return M.render_edit_with_fragments(old_string, new_string).lines
end

--- Render a diff plus reconstructed before/after source fragments.
---@param old_string string?
---@param new_string string?
---@return { lines: string[], before: table?, after: table?, glyph_col: integer }
function M.render_edit_with_fragments(old_string, new_string)
  old_string = old_string or ''
  new_string = new_string or ''
  if not old_string:match('\n$') then old_string = old_string .. '\n' end
  if not new_string:match('\n$') then new_string = new_string .. '\n' end

  local diff_str = vim.diff(old_string, new_string, {
    result_type = 'unified',
    ctxlen = 2,
    algorithm = 'histogram',
  })
  if type(diff_str) ~= 'string' or diff_str == '' then
    return { lines = {}, glyph_col = DIFF_GLYPH_COL }
  end

  local lines = {}
  local before_rows, before_idx = {}, {}
  local after_rows, after_idx   = {}, {}

  for _, raw in ipairs(vim.split(diff_str, '\n', { plain = true })) do
    if raw == '' then
      -- skip
    elseif raw:sub(1, 3) == '---' or raw:sub(1, 3) == '+++' then
      -- skip file headers
    else
      local body_idx = #lines  -- 0-indexed index of the line we're about to push
      table.insert(lines, INDENT .. raw)
      local glyph = raw:sub(1, 1)
      if glyph == '@' then
        -- hunk header — not part of either fragment
      else
        local code = raw:sub(2)
        if glyph == '+' then
          table.insert(after_rows, code)
          table.insert(after_idx, body_idx)
        elseif glyph == '-' then
          table.insert(before_rows, code)
          table.insert(before_idx, body_idx)
        else
          -- context line (' ')
          table.insert(after_rows, code)
          table.insert(after_idx, body_idx)
          table.insert(before_rows, code)
          table.insert(before_idx, body_idx)
        end
      end
    end
  end

  local function build(rows, idx)
    if #rows == 0 then return nil end
    local row_map = {}
    for i, body_idx in ipairs(idx) do
      row_map[i] = { body_idx = body_idx, col_offset = DIFF_TEXT_COL }
    end
    return { text = table.concat(rows, '\n'), row_map = row_map }
  end

  return {
    lines = lines,
    after = build(after_rows, after_idx),
    before = build(before_rows, before_idx),
    glyph_col = DIFF_GLYPH_COL,
  }
end

--- Render the initial content of a Write tool call (no diff vs disk —
--- we'd need to read the file and we don't want side effects).
---@param content string?
---@return string[] lines
function M.render_write(content)
  return M.render_write_with_fragments(content).lines
end

--- Render Write content plus a single "after" fragment over the new content.
---@param content string?
---@return { lines: string[], after: table?, glyph_col: integer }
function M.render_write_with_fragments(content)
  content = content or ''
  local lines = {}
  local rows = {}
  local idx = {}
  for _, line in ipairs(vim.split(content, '\n', { plain = true })) do
    local body_idx = #lines
    table.insert(lines, INDENT .. '+ ' .. line)
    table.insert(rows, line)
    table.insert(idx, body_idx)
  end
  local after
  if #rows > 0 then
    local row_map = {}
    for i, body_idx in ipairs(idx) do
      row_map[i] = { body_idx = body_idx, col_offset = WRITE_TEXT_COL }
    end
    after = { text = table.concat(rows, '\n'), row_map = row_map }
  end
  return { lines = lines, after = after, glyph_col = DIFF_GLYPH_COL }
end

--- Summary for a MultiEdit input.
---@param edits table[]
---@return string[] lines
function M.render_multiedit(edits)
  return M.render_multiedit_with_fragments(edits).lines
end

--- Render a MultiEdit plus per-edit before/after fragments. Each entry of
--- `fragments` corresponds to one edit (in order); entry's row_map indices
--- already point at the merged `lines` array.
---@param edits table[]?
---@return { lines: string[], fragments: table[], glyph_col: integer }
function M.render_multiedit_with_fragments(edits)
  local lines = {}
  local fragments = {}
  for i, edit in ipairs(edits or {}) do
    table.insert(lines, INDENT .. string.format('── edit %d ──', i))
    local sub = M.render_edit_with_fragments(edit.old_string, edit.new_string)
    local offset = #lines  -- 0-indexed start of sub.lines in `lines`
    for _, l in ipairs(sub.lines) do
      table.insert(lines, l)
    end
    local function shift(snip)
      if not snip then return nil end
      local row_map = {}
      for j, m in ipairs(snip.row_map) do
        row_map[j] = { body_idx = m.body_idx + offset, col_offset = m.col_offset }
      end
      return { text = snip.text, row_map = row_map }
    end
    table.insert(fragments, { after = shift(sub.after), before = shift(sub.before) })
  end
  return { lines = lines, fragments = fragments, glyph_col = DIFF_GLYPH_COL }
end

return M
