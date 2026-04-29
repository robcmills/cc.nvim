-- Tool input rendering: YAML-ish bodies, per-tool body customization, and
-- the one-line summary used in tool headers + foldtext.
-- Pure functions — no buffer state.

local M = {}

--- Tools whose summary should appear only in the foldtext when collapsed,
--- never on the unfolded header line. The summary would otherwise duplicate
--- a field already visible in the expanded YAML-ish body below the header.
M.SUMMARY_FOLD_ONLY = {
  ToolSearch = true,
}

--- Render a YAML-ish representation of a Lua value.
--- Simple types render as `key: value`. Nested tables recurse.
--- Multi-line strings use `key: |` block-scalar form.
---@param value any
---@param indent string
---@return string[]
local function render_yaml_ish(value, indent)
  indent = indent or ''
  local out = {}
  if type(value) ~= 'table' then
    if type(value) == 'string' and value:find('\n') then
      table.insert(out, indent .. '|')
      for _, l in ipairs(vim.split(value, '\n', { plain = true })) do
        table.insert(out, indent .. '  ' .. l)
      end
    else
      table.insert(out, indent .. tostring(value))
    end
    return out
  end
  local is_array = #value > 0 and next(value, #value) == nil
  if is_array then
    for _, v in ipairs(value) do
      if type(v) == 'table' then
        table.insert(out, indent .. '-')
        for _, l in ipairs(render_yaml_ish(v, indent .. '  ')) do
          table.insert(out, l)
        end
      elseif type(v) == 'string' and v:find('\n') then
        table.insert(out, indent .. '- |')
        for _, l in ipairs(vim.split(v, '\n', { plain = true })) do
          table.insert(out, indent .. '    ' .. l)
        end
      else
        table.insert(out, indent .. '- ' .. tostring(v))
      end
    end
  else
    local keys = {}
    for k in pairs(value) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local v = value[k]
      if type(v) == 'table' then
        table.insert(out, indent .. tostring(k) .. ':')
        for _, l in ipairs(render_yaml_ish(v, indent .. '  ')) do
          table.insert(out, l)
        end
      elseif type(v) == 'string' and v:find('\n') then
        table.insert(out, indent .. tostring(k) .. ': |')
        for _, l in ipairs(vim.split(v, '\n', { plain = true })) do
          table.insert(out, indent .. '  ' .. l)
        end
      else
        table.insert(out, indent .. tostring(k) .. ': ' .. tostring(v))
      end
    end
  end
  return out
end
M.render_yaml_ish = render_yaml_ish

--- Status marker for a TodoWrite item. Glyphs chosen from blocks (Dingbats /
--- Geometric Shapes) with reliable monospace-font coverage so the terminal
--- doesn't fall back to a differently-sized fallback font.
local function todo_marker(status)
  if status == 'completed' then return '✓' end
  if status == 'in_progress' then return '◐' end
  return '□'
end

--- Per-tool snippet language hints. Entries keyed by tool name; `input` maps
--- input field names (top-level keys) to the TS language to highlight that
--- field's value as. The renderer scans the YAML-ish body for `<key>: |` block
--- scalars and applies highlights to their content.
local TOOL_LANGS = {
  ['mcp__claude-in-chrome__javascript_tool'] = { input = { text = 'javascript' } },
}

--- Build a fragment covering every line of a YAML-ish body for top-level
--- `yaml` highlighting. Each source row maps 1:1 to body_lines[i] at
--- col_offset = 0; the surrounding renderer adds the buffer indent.
---@param body_lines string[]
---@return { text: string, row_map: table[] }?
local function full_body_fragment(body_lines)
  if not body_lines or #body_lines == 0 then return nil end
  local row_map = {}
  for i = 1, #body_lines do
    row_map[i] = { body_idx = i - 1, col_offset = 0 }
  end
  return { text = table.concat(body_lines, '\n'), row_map = row_map }
end
M.full_body_fragment = full_body_fragment

--- Find a top-level `<key>: ...` scalar in a YAML-ish body and return a
--- fragment {text, row_map} suitable for cc.tshl. Handles both the block
--- form (`<key>: |` followed by 2-space-indented lines) and the inline form
--- (`<key>: <value>` on a single line, used when the value has no newlines).
--- row_map body_idx entries are 0-indexed into `body_lines`.
---@param body_lines string[]
---@param key string
---@return { text: string, row_map: table[] }?
local function extract_yaml_scalar(body_lines, key)
  local block_header = key .. ': |'
  local inline_prefix = key .. ': '
  for i, l in ipairs(body_lines) do
    if l == block_header then
      local rows = {}
      local row_map = {}
      for j = i + 1, #body_lines do
        local m = body_lines[j]
        if m:sub(1, 2) == '  ' then
          table.insert(rows, m:sub(3))
          table.insert(row_map, { body_idx = j - 1, col_offset = 2 })
        else
          break
        end
      end
      if #rows == 0 then return nil end
      return { text = table.concat(rows, '\n'), row_map = row_map }
    elseif l:sub(1, #inline_prefix) == inline_prefix then
      local value = l:sub(#inline_prefix + 1)
      if value == '' then return nil end
      return {
        text = value,
        row_map = { { body_idx = i - 1, col_offset = #inline_prefix } },
      }
    end
  end
  return nil
end
M.extract_yaml_scalar = extract_yaml_scalar

--- Default body formatter. Returns either `string[]` (lines only) or
--- `{ lines, snippets }` where `snippets[i] = { lang, fragment = {text, row_map} }`
--- and `row_map`'s body_idx is 0-indexed into `lines`.
---@param tool_name string
---@param input table
---@return string[]|{ lines: string[], snippets: table[] }?
function M.default_tool_body(tool_name, input)
  if tool_name == 'Bash' and input.command then
    return vim.split(tostring(input.command), '\n', { plain = true })
  elseif tool_name == 'Edit' then
    local d = require('cc.diff').render_edit_with_fragments(input.old_string, input.new_string)
    local snippets = {}
    local lang = require('cc.tshl').lang_for_path(input.file_path)
    if lang then
      if d.after  then table.insert(snippets, { lang = lang, fragment = d.after  }) end
      if d.before then table.insert(snippets, { lang = lang, fragment = d.before }) end
    end
    return { lines = d.lines, snippets = snippets }
  elseif tool_name == 'MultiEdit' then
    local d = require('cc.diff').render_multiedit_with_fragments(input.edits)
    local snippets = {}
    local lang = require('cc.tshl').lang_for_path(input.file_path)
    if lang then
      for _, frag in ipairs(d.fragments) do
        if frag.after  then table.insert(snippets, { lang = lang, fragment = frag.after  }) end
        if frag.before then table.insert(snippets, { lang = lang, fragment = frag.before }) end
      end
    end
    return { lines = d.lines, snippets = snippets }
  elseif tool_name == 'Write' then
    local d = require('cc.diff').render_write_with_fragments(input.content)
    local snippets = {}
    local lang = require('cc.tshl').lang_for_path(input.file_path)
    if lang and d.after then
      table.insert(snippets, { lang = lang, fragment = d.after })
    end
    return { lines = d.lines, snippets = snippets }
  elseif tool_name == 'TodoWrite' and type(input.todos) == 'table' then
    local lines = {}
    for _, t in ipairs(input.todos) do
      local text = t.content or t.activeForm or ''
      table.insert(lines, todo_marker(t.status) .. ' ' .. tostring(text))
    end
    return lines
  end
  -- `description` and other fields already shown in the fold summary header.
  local read_skip = { file_path = true, offset = true, limit = true }
  local filtered = {}
  for k, v in pairs(input) do
    local skip = k == 'description'
      or (tool_name == 'Read' and read_skip[k])
      or (tool_name == 'Glob' and k == 'pattern')
      or (tool_name == 'Grep' and k == 'pattern')
      or (tool_name == 'WebFetch' and k == 'url')
      or (tool_name == 'WebSearch' and k == 'query')
      or (tool_name == 'Skill' and k == 'skill')
    if not skip then
      filtered[k] = v
    end
  end
  local lines = render_yaml_ish(filtered, '')
  local snippets = {}
  -- Top-level YAML highlight for the whole body. Placed first so any
  -- per-tool fine-grained snippet (e.g. javascript_tool's `text:` value)
  -- overlays it.
  local yaml_frag = full_body_fragment(lines)
  if yaml_frag then
    table.insert(snippets, { lang = 'yaml', fragment = yaml_frag })
  end
  local lang_spec = TOOL_LANGS[tool_name]
  if lang_spec and lang_spec.input then
    for key, lang in pairs(lang_spec.input) do
      if filtered[key] ~= nil then
        local frag = extract_yaml_scalar(lines, key)
        if frag then
          table.insert(snippets, { lang = lang, fragment = frag })
        end
      end
    end
  end
  if #snippets > 0 then
    return { lines = lines, snippets = snippets }
  end
  return lines
end

--- Compact one-line summary of a tool input (used in tool header suffix).
---@param tool_name string
---@param input table?
---@return string
function M.summarize_tool_input(tool_name, input)
  if not input or type(input) ~= 'table' then
    return ''
  end
  if tool_name == 'Bash' then
    if input.description and input.description ~= '' then
      return tostring(input.description)
    end
    local cmd = tostring(input.command or ''):gsub('\n', ' ')
    if #cmd > 80 then cmd = cmd:sub(1, 77) .. '...' end
    return cmd
  elseif tool_name == 'Read' then
    local path = input.file_path or ''
    if input.offset or input.limit then
      path = path .. ':' .. tostring(input.offset or 1) .. '-' ..
        tostring((input.offset or 1) + (input.limit or 0))
    end
    return path
  elseif tool_name == 'Edit' or tool_name == 'Write' or tool_name == 'NotebookEdit' then
    return input.file_path or ''
  elseif tool_name == 'Glob' then
    return input.pattern or ''
  elseif tool_name == 'Grep' then
    return '"' .. (input.pattern or '') .. '"'
  elseif tool_name == 'WebFetch' then
    return input.url or ''
  elseif tool_name == 'WebSearch' then
    return input.query or ''
  elseif tool_name == 'TodoWrite' then
    return (input.todos and ('#' .. #input.todos)) or ''
  elseif tool_name == 'Agent' then
    return input.description or ''
  elseif tool_name == 'Skill' then
    return input.skill or ''
  elseif tool_name == 'ToolSearch' then
    local q = tostring(input.query or '')
    if #q > 80 then q = q:sub(1, 77) .. '...' end
    return q
  end
  -- MCP tools (mcp__*) render their input as a YAML-ish body below the
  -- header; a JSON-encoded suffix would just duplicate that.
  if tool_name:sub(1, 5) == 'mcp__' then
    return ''
  end
  local ok, s = pcall(vim.json.encode, input)
  if ok and s then
    if #s > 80 then s = s:sub(1, 77) .. '...' end
    return s
  end
  return ''
end

return M
