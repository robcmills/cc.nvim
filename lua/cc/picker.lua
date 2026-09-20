-- Floating-window picker. Used in place of `vim.ui.select` when we want a
-- large window that can show wide, multi-column rows (e.g. session history).
-- Width/height scale with the editor; navigation uses normal-mode motions.

local M = {}

---@class cc.PickerHandle
---@field bufnr integer
---@field winid integer
---@field dismiss fun() Close without invoking the callback, including a queued choice.

---@param bufnr integer
---@param winid integer
---@param on_choice function
---@param before_close fun()?
---@return cc.PickerHandle handle, function finish
local function lifecycle(bufnr, winid, on_choice, before_close)
  local done, dismissed = false, false
  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      if before_close then before_close() end
      vim.api.nvim_win_close(winid, true)
    end
  end
  local function finish(item, idx)
    if done then return end
    done = true
    close()
    vim.schedule(function()
      if not dismissed then on_choice(item, idx) end
    end)
  end
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = bufnr,
    once = true,
    callback = function() finish(nil, nil) end,
  })
  return {
    bufnr = bufnr,
    winid = winid,
    dismiss = function()
      dismissed = true
      done = true
      close()
    end,
  }, finish
end

--- Open a floating picker over `items`.
---@param items any[]
---@param opts { prompt: string?, format_item: (fun(item: any): string)? }
---@param on_choice fun(item: any?, idx: integer?)
---@return cc.PickerHandle
function M.select(items, opts, on_choice)
  opts = opts or {}
  local format_item = opts.format_item or tostring
  local prompt = (opts.prompt or 'Select'):gsub('\n', ' ')

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
  -- Requests can arrive while the user is typing in the conversation prompt.
  vim.cmd('stopinsert')

  local handle, finish = lifecycle(bufnr, winid, on_choice)

  local function accept()
    if not vim.api.nvim_win_is_valid(winid) then return end
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

  return handle
end

--- Open a dismissable, single-line text input. Escape cancels in either mode;
--- q cancels in normal mode and remains ordinary text in insert mode.
---@param opts { prompt: string }
---@param on_submit fun(text: string?)
---@return cc.PickerHandle
function M.input(opts, on_submit)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  local width = math.min(80, math.max(vim.o.columns - 4, 1))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = width,
    height = 1,
    row = math.max(0, math.floor(vim.o.lines / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. opts.prompt:gsub('\n', ' ') .. ' ',
    title_pos = 'center',
  })
  local handle, finish = lifecycle(bufnr, winid, on_submit, function()
    if vim.api.nvim_get_current_win() == winid then vim.cmd('stopinsert') end
  end)
  vim.keymap.set({ 'n', 'i' }, '<CR>', function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    finish(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  end, { buffer = bufnr, nowait = true, silent = true })
  for _, key in ipairs({ '<Esc>', '<C-c>' }) do
    vim.keymap.set({ 'n', 'i' }, key, function() finish(nil) end,
      { buffer = bufnr, nowait = true, silent = true })
  end
  vim.keymap.set('n', 'q', function() finish(nil) end,
    { buffer = bufnr, nowait = true, silent = true })
  vim.cmd('startinsert')
  return handle
end

return M
