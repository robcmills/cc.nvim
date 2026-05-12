-- Floating-window picker. Used in place of `vim.ui.select` when we want a
-- large window that can show wide, multi-column rows (e.g. session history).
-- Width/height scale with the editor; navigation uses normal-mode motions.

local M = {}

--- Open a floating picker over `items`.
---@param items any[]
---@param opts { prompt: string?, format_item: (fun(item: any): string)? }
---@param on_choice fun(item: any?, idx: integer?)
function M.select(items, opts, on_choice)
  opts = opts or {}
  local format_item = opts.format_item or tostring
  local prompt = opts.prompt or 'Select'

  local lines = {}
  local max_w = 0
  for _, item in ipairs(items) do
    local s = format_item(item)
    s = s:gsub('\n', ' ')
    table.insert(lines, s)
    local w = vim.fn.strdisplaywidth(s)
    if w > max_w then max_w = w end
  end

  local screen_w = vim.o.columns
  local screen_h = vim.o.lines
  local width = math.min(math.max(max_w + 4, 80), math.max(screen_w - 4, 40))
  local height = math.min(math.max(#lines, 10), math.max(screen_h - 6, 10))
  local row = math.max(0, math.floor((screen_h - height) / 2) - 1)
  local col = math.max(0, math.floor((screen_w - width) / 2))

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. prompt .. ' ',
    title_pos = 'center',
    footer = ' <CR> select   <Esc>/q cancel ',
    footer_pos = 'right',
  })
  vim.wo[winid].cursorline = true
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = 'no'

  local done = false
  local function finish(item, idx)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
    vim.schedule(function() on_choice(item, idx) end)
  end

  local function accept()
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local idx = cursor[1]
    finish(items[idx], idx)
  end
  local function cancel() finish(nil, nil) end

  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = bufnr, nowait = true, silent = true })
  end
  map('<CR>', accept)
  map('<2-LeftMouse>', accept)
  map('<Esc>', cancel)
  map('q', cancel)
  map('<C-c>', cancel)

  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = bufnr,
    once = true,
    callback = cancel,
  })
end

return M
