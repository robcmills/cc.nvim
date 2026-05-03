-- Inline placeholder text for the prompt buffer. Shown via `virt_text`
-- overlaid on line 1 when the buffer is empty (or whitespace-only); cleared
-- as soon as the user types. Text and visibility are driven by
-- `config.prompt_placeholder` (a string, or false/'' to disable).

local M = {}

local NS = vim.api.nvim_create_namespace('cc.placeholder')

-- bufnr -> extmark id
local extmarks = {}
-- bufnr -> per-buffer override text (wins over config.prompt_placeholder)
local overrides = {}

---@param bufnr integer
---@return table[]? virt_text spec, or nil if disabled
local function build_virt_text(bufnr)
  local text = overrides[bufnr]
  if text == nil then
    local Config = require('cc.config')
    text = Config.options.prompt_placeholder
  end
  if not text or text == '' then return nil end
  return { { text, 'CcPromptPlaceholder' } }
end

--- Set a per-buffer placeholder text override that takes precedence over
--- `config.prompt_placeholder`. Pass nil to clear the override.
---@param bufnr integer
---@param text string?
function M.set_text(bufnr, text)
  if not bufnr or bufnr <= 0 then return end
  overrides[bufnr] = text
  M.render(bufnr)
end

---@param bufnr integer
---@return boolean
local function is_buffer_empty(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then return true end
  if #lines > 1 then return false end
  return lines[1] == ''
end

--- Render the placeholder if the buffer is empty and config enables it.
--- Idempotent: existing extmark is reused via `id`.
---@param bufnr integer
function M.render(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local virt = build_virt_text(bufnr)
  if not virt or not is_buffer_empty(bufnr) then
    M.clear(bufnr)
    return
  end
  local opts = {
    virt_text = virt,
    virt_text_pos = 'overlay',
    hl_mode = 'combine',
  }
  local existing = extmarks[bufnr]
  if existing then opts.id = existing end
  extmarks[bufnr] = vim.api.nvim_buf_set_extmark(bufnr, NS, 0, 0, opts)
end

---@param bufnr integer
function M.clear(bufnr)
  if not bufnr then return end
  local id = extmarks[bufnr]
  if id and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, id)
  end
  extmarks[bufnr] = nil
end

--- Attach autocmds that keep the placeholder in sync with buffer content.
--- TextChanged / TextChangedI cover user edits; BufWinEnter covers the
--- initial display. Programmatic clears (`nvim_buf_set_lines`) do not fire
--- TextChanged, so callers that wipe the buffer should also call `render`.
---@param bufnr integer
function M.attach(bufnr)
  if not bufnr or bufnr <= 0 then return end
  local group = vim.api.nvim_create_augroup('cc.placeholder.' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWinEnter' }, {
    group = group,
    buffer = bufnr,
    callback = function() M.render(bufnr) end,
  })
  M.render(bufnr)
end

---@param bufnr integer
function M.detach(bufnr)
  if not bufnr or bufnr <= 0 then return end
  pcall(vim.api.nvim_del_augroup_by_name, 'cc.placeholder.' .. bufnr)
  M.clear(bufnr)
  overrides[bufnr] = nil
end

return M
