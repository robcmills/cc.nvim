-- Inline diffs for Edit/MultiEdit/Write tool inputs.
-- Produces line-array output with - / + prefixes and a fold level array.

local M = {}

local INDENT = '        '

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
  old_string = old_string or ''
  new_string = new_string or ''
  -- vim.diff expects strings ending in newline; normalize.
  if not old_string:match('\n$') then old_string = old_string .. '\n' end
  if not new_string:match('\n$') then new_string = new_string .. '\n' end
  return M.unified(old_string, new_string)
end

--- Render the initial content of a Write tool call (no diff vs disk —
--- we'd need to read the file and we don't want side effects).
---@param content string?
---@return string[] lines
function M.render_write(content)
  content = content or ''
  local out = {}
  for _, line in ipairs(vim.split(content, '\n', { plain = true })) do
    table.insert(out, INDENT .. '+ ' .. line)
  end
  return out
end

--- Summary for a MultiEdit input.
---@param edits table[]
---@return string[] lines
function M.render_multiedit(edits)
  local out = {}
  for i, edit in ipairs(edits or {}) do
    table.insert(out, INDENT .. string.format('── edit %d ──', i))
    local diff_lines = M.render_edit(edit.old_string, edit.new_string)
    for _, l in ipairs(diff_lines) do
      table.insert(out, l)
    end
  end
  return out
end

return M
