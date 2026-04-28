-- Treesitter-based syntax highlighter for snippets embedded in the cc output
-- buffer (tool input code, diff hunks).
--
-- Parses an arbitrary string with a TS language and applies extmark highlights
-- at caller-specified buffer positions. Source rows in the snippet may map to
-- non-contiguous buffer rows (used for diff "after" / "before" reconstructed
-- fragments where context lines appear in both).
--
-- No-ops when the requested parser isn't available — keeps the plugin usable
-- for users without TS parsers installed.

local M = {}

local NS = vim.api.nvim_create_namespace('cc.tshl')

function M.namespace() return NS end

--- Resolve a Vim filetype to a TS language name. Returns nil if no parser is
--- registered for that filetype.
---@param filetype string
---@return string?
function M.lang_for_filetype(filetype)
  if not filetype or filetype == '' then return nil end
  local lang = vim.treesitter.language.get_lang(filetype)
  return lang or filetype
end

--- Common ambiguous extensions that vim.filetype.match leaves nil without a
--- buffer to inspect (e.g. ".ts" is TypeScript / XQuery / Tcl). Resolved by
--- the most-likely choice for code we render from tools.
local EXT_FALLBACK = {
  ts = 'typescript',
  tsx = 'typescriptreact',
}

--- Detect a filetype from a file path (without requiring the file to exist).
---@param path string?
---@return string?
function M.filetype_for_path(path)
  if not path or path == '' then return nil end
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if ok and type(ft) == 'string' and ft ~= '' then return ft end
  local ext = path:match('%.([%w]+)$')
  return ext and EXT_FALLBACK[ext:lower()] or nil
end

--- Convenience: filetype → TS lang in one step.
---@param path string?
---@return string?
function M.lang_for_path(path)
  local ft = M.filetype_for_path(path)
  if not ft then return nil end
  return M.lang_for_filetype(ft)
end

--- True if a TS parser for `lang` is available.
---@param lang string?
---@return boolean
function M.has_parser(lang)
  if not lang or lang == '' then return false end
  local ok, parser_or_err = pcall(vim.treesitter.language.add, lang)
  if ok and parser_or_err then return true end
  return false
end

--- Translate a (source_row, source_col) range to a buffer position via row_map.
--- row_map[i] (1-indexed; corresponds to source row i-1) = { row, col_offset }.
--- `row` is 0-indexed buffer row; `col_offset` is 0-indexed column where source
--- column 0 lands in the buffer.
local function map_pos(row_map, sr, sc)
  local entry = row_map[sr + 1]
  if not entry then return nil end
  return entry.row, entry.col_offset + sc
end

--- Apply TS highlights to `text` parsed as `lang`, mapping each source row to
--- a buffer row + column offset via `row_map`.
---
--- Multi-line captures are split into per-row extmarks so each line gets the
--- correct buffer position from `row_map`.
---
---@param bufnr integer
---@param lang string
---@param text string snippet source (no leading per-line indent)
---@param row_map { row: integer, col_offset: integer }[] 1-indexed; entry i corresponds to source row i-1
---@return boolean applied true if highlights were applied; false if no parser
function M.apply_fragment(bufnr, lang, text, row_map)
  if not M.has_parser(lang) then return false end
  if not text or text == '' or #row_map == 0 then return false end

  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok_parser or not parser then return false end

  local trees = parser:parse()
  if not trees or not trees[1] then return false end
  local root = trees[1]:root()

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then return false end

  local source_lines = vim.split(text, '\n', { plain = true })

  for id, node in query:iter_captures(root, text, 0, -1) do
    local name = query.captures[id]
    if name and not name:match('^_') then
      local hl = '@' .. name
      local sr, sc, er, ec = node:range()
      if sr == er then
        local brow, bcol = map_pos(row_map, sr, sc)
        if brow then
          local _, bcol_end = map_pos(row_map, er, ec)
          if bcol_end then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, brow, bcol, {
              end_row = brow,
              end_col = bcol_end,
              hl_group = hl,
              priority = 110,
            })
          end
        end
      else
        -- Multi-line capture: emit one extmark per row of the source the
        -- capture spans, since each row may map to a different buffer row.
        for r = sr, er do
          local row_text = source_lines[r + 1] or ''
          local col_start = (r == sr) and sc or 0
          local col_end = (r == er) and ec or #row_text
          local brow, bcol = map_pos(row_map, r, col_start)
          if brow then
            local _, bcol_end = map_pos(row_map, r, col_end)
            if bcol_end and bcol_end > bcol then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, brow, bcol, {
                end_row = brow,
                end_col = bcol_end,
                hl_group = hl,
                priority = 110,
              })
            end
          end
        end
      end
    end
  end

  return true
end

return M
