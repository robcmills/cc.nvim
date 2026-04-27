-- Prompt window autosize: grow the prompt window to fit content (counted as
-- wrapped display rows), clamped to [prompt_height, prompt_max_height].
-- Manual `:resize` on the prompt window disables autosize for the instance
-- until the next prompt clear (which resets the flag) or :CcPromptAutosize on.

local Config = require('cc.config')

local M = {}

---@param winid integer
---@param bufnr integer
---@return integer rows total wrapped display rows for buffer in this window
local function compute_display_rows(winid, bufnr)
  local width = vim.api.nvim_win_get_width(winid)
  if width <= 0 then return 1 end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then return 1 end
  local total = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w == 0 then
      total = total + 1
    else
      total = total + math.ceil(w / width)
    end
  end
  return total
end

--- Resize the prompt window to fit content. No-op if autosize is disabled,
--- the window is invalid, or the prompt buffer no longer occupies it.
---@param inst cc.Instance
function M.resize(inst)
  if not inst or inst.autosize_disabled then return end
  local winid = inst.prompt_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local bufnr = inst.prompt and inst.prompt.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then return end

  local cfg = Config.options
  local default = cfg.prompt_height or 10
  local max = math.max(default, cfg.prompt_max_height or default)
  local rows = compute_display_rows(winid, bufnr)
  local desired = math.max(default, math.min(max, rows))

  -- Update expected first: WinResized may fire async (next event-loop tick),
  -- so a flag-based guard would race. The equality check `current==expected`
  -- works regardless of when the event fires.
  inst.expected_prompt_height = desired
  if vim.api.nvim_win_get_height(winid) ~= desired then
    pcall(vim.api.nvim_win_set_height, winid, desired)
  end
end

--- Clear any manual-override flag and resize. Called after prompt clear so
--- a fresh empty prompt collapses back to the default height.
---@param inst cc.Instance
function M.reset(inst)
  if not inst then return end
  inst.autosize_disabled = false
  M.resize(inst)
end

--- Toggle autosize on/off. Pass 'on' or 'off' to set explicitly; nil toggles.
--- Returns the new enabled state (true = autosize active).
---@param inst cc.Instance
---@param state 'on'|'off'|nil
---@return boolean enabled
function M.toggle(inst, state)
  if not inst then return false end
  if state == 'on' then
    inst.autosize_disabled = false
  elseif state == 'off' then
    inst.autosize_disabled = true
  else
    inst.autosize_disabled = not inst.autosize_disabled
  end
  if not inst.autosize_disabled then M.resize(inst) end
  return not inst.autosize_disabled
end

--- Attach autosize autocmds to the instance's prompt buffer.
---@param inst cc.Instance
function M.attach(inst)
  if not inst or not inst.prompt then return end
  local prompt_bufnr = inst.prompt.bufnr
  if not prompt_bufnr or prompt_bufnr <= 0 then return end
  local group = vim.api.nvim_create_augroup('cc.autosize.' .. prompt_bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = prompt_bufnr,
    callback = function()
      -- If autosize was disabled by a manual resize, re-enable as soon as
      -- the user empties the prompt. "Empty" = no non-whitespace chars,
      -- matching what `Prompt:clear()` produces.
      if inst.autosize_disabled and inst.prompt and not inst.prompt:has_content() then
        inst.autosize_disabled = false
      end
      M.resize(inst)
    end,
  })

  -- WinResized fires after a window's size changes for any reason. Our own
  -- resizes pre-update inst.expected_prompt_height, so they pass the
  -- equality check in `_handle_winresized`. Anything else (user `:resize`,
  -- terminal resize) yields current ≠ expected → flip autosize off until
  -- the next clear.
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      local windows = (vim.v.event and vim.v.event.windows) or {}
      M._handle_winresized(inst, windows)
    end,
  })
end

--- Called when WinResized fires. Exposed so tests can drive it directly
--- without faking v:event.windows. If any of `resized_winids` matches the
--- prompt window AND its height no longer equals what we last set, the
--- user must have resized it manually — disable autosize until the next
--- clear (which calls `reset`).
---@param inst cc.Instance
---@param resized_winids integer[]
function M._handle_winresized(inst, resized_winids)
  if not inst then return end
  local winid = inst.prompt_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local matched = false
  for _, w in ipairs(resized_winids or {}) do
    if w == winid then matched = true; break end
  end
  if not matched then return end
  local current = vim.api.nvim_win_get_height(winid)
  if inst.expected_prompt_height and current ~= inst.expected_prompt_height then
    inst.autosize_disabled = true
    inst.expected_prompt_height = current
  end
end

--- Tear down autocmds for an instance whose prompt buffer is going away.
---@param prompt_bufnr integer
function M.detach(prompt_bufnr)
  if not prompt_bufnr or prompt_bufnr <= 0 then return end
  pcall(vim.api.nvim_del_augroup_by_name, 'cc.autosize.' .. prompt_bufnr)
end

return M
