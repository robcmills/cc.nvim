-- Prompt buffer: editable markdown buffer for composing messages.
-- Submission reads content, clears the buffer, caller forwards to process.

local M = {}

---@class cc.Prompt
---@field bufnr integer
---@field winid integer?
local Prompt = {}
Prompt.__index = Prompt

local BUF_NAME_DEFAULT = 'cc-nvim-prompt'

---@param buf_name string? override buffer name (for multiple instances)
function M.new(buf_name)
  return setmetatable({
    bufnr = -1,
    winid = nil,
    buf_name = buf_name or BUF_NAME_DEFAULT,
  }, Prompt)
end

function Prompt:ensure_buffer()
  if self.bufnr > 0 and vim.api.nvim_buf_is_valid(self.bufnr) then
    return self.bufnr
  end
  self.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.bufnr, self.buf_name)
  vim.bo[self.bufnr].buftype = 'nofile'
  vim.bo[self.bufnr].bufhidden = 'hide'
  vim.bo[self.bufnr].buflisted = false
  vim.bo[self.bufnr].swapfile = false

  -- nvim_create_buf() does not emit the read lifecycle events used by plugin
  -- managers to lazy-load buffer integrations. Run BufReadPost before
  -- FileType, matching the useful part of the lifecycle of an ordinary file.
  -- This is important for nvim-treesitter: besides starting the highlighter,
  -- its setup registers aliases such as `ts` -> `typescript` that markdown
  -- fenced-code injections rely on.
  pcall(vim.api.nvim_buf_call, self.bufnr, function()
    vim.api.nvim_exec_autocmds('BufReadPost', {
      buffer = self.bufnr,
      modeline = false,
    })
  end)

  vim.bo[self.bufnr].filetype = 'markdown'

  -- FileType callbacks run synchronously, making this late enough for
  -- filetype-triggered markdown plugins to finish loading. Start the native
  -- highlighter as a fallback for configurations that do not use
  -- nvim-treesitter's highlight module. Missing parsers are fine: markdown
  -- remains usable with its regular syntax highlighting.
  if not vim.treesitter.highlighter.active[self.bufnr] then
    pcall(vim.treesitter.start, self.bufnr, 'markdown')
  end

  -- Omnifunc fallback for users without nvim-cmp.
  vim.bo[self.bufnr].omnifunc = "v:lua.require'cc.prompt'.omnifunc"

  self:_setup_window_opts_for_buffer()
  self:_guard_buflisted()

  -- If nvim-cmp is available, override buffer-local sources so our slash
  -- source wins over the user's global `path` source (which would otherwise
  -- expand `/` to filesystem paths). `cmp.setup.buffer` reads
  -- `nvim_get_current_buf()` internally, so we must enter the prompt buffer
  -- before calling it — at this point it was just created via `nvim_create_buf`
  -- and isn't current yet.
  local ok_cmp, cmp = pcall(require, 'cmp')
  if ok_cmp then
    pcall(function()
      vim.api.nvim_buf_call(self.bufnr, function()
        cmp.setup.buffer({
          sources = cmp.config.sources(
            { { name = 'cc_slash' } },
            { { name = 'path' } },
            { { name = 'buffer' } }
          ),
        })
      end)
    end)
  end

  return self.bufnr
end

--- Omnifunc for slash command completion. Fallback for users without nvim-cmp.
--- Invoked twice: findstart=1 returns the starting column; findstart=0 with
--- the base prefix returns the matches.
---@param findstart integer 0 | 1
---@param base string? the partial word when findstart=0
---@return integer|table
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    -- Find the `/` at or before col.
    local before = line:sub(1, col)
    local slash = before:find('/[^%s/]*$')
    if not slash then return -1 end
    return slash - 1 -- 0-indexed start column (omnifunc convention)
  end
  -- findstart == 0: return matches
  local ok_cc, cc = pcall(require, 'cc')
  local session_cmds = ok_cc and cc.get_slash_commands() or nil
  local session_skills = ok_cc and cc.get_skills() or nil
  local cmds = require('cc.slash').list(session_cmds, session_skills)
  local matches = {}
  local prefix = (base or ''):gsub('^/', '')
  for _, c in ipairs(cmds) do
    if prefix == '' or c.name:sub(1, #prefix) == prefix then
      table.insert(matches, {
        word = '/' .. c.name,
        abbr = '/' .. c.name,
        menu = c.description or c.source or '',
      })
    end
  end
  return matches
end

--- Re-assert `buflisted = false` on events that flip it back on. Vim's
--- `:edit <buffer-name>` (used by some pickers and any direct `:e` of the
--- prompt buffer's path) flips buflisted=true via BufAdd; without this
--- guard, the prompt then leaks into buffer-list sidebars. Hooking BufAdd
--- and BufEnter covers both the natural `:edit` flow and any plugin that
--- sets buflisted=true and then triggers BufEnter.
function Prompt:_guard_buflisted()
  local bufnr = self.bufnr
  local group = vim.api.nvim_create_augroup('cc.prompt.buflisted.' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufAdd', 'BufEnter' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if vim.bo[bufnr].buflisted then
        vim.bo[bufnr].buflisted = false
      end
    end,
  })
end

--- Options cc overrides on the prompt window. Saved on entry, restored on
--- BufWinLeave so they don't leak to buffers that later occupy the window.
local PROMPT_WIN_OPTS = { 'number', 'relativenumber', 'signcolumn', 'wrap' }

--- Configure window-local options on windows showing this prompt buffer.
function Prompt:_setup_window_opts_for_buffer()
  local bufnr = self.bufnr
  local winopts = require('cc.winopts')
  local group = vim.api.nvim_create_augroup('cc.prompt.win.' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        return
      end
      local config = require('cc.config').options
      -- Source the restore baseline from inst.user_winopts (captured in
      -- create_instance before any cc autocmd fired). The prompt window
      -- is normally created via `:split` from the output window, so its
      -- inherited window-local values already reflect cc's overrides;
      -- and for "g+l" options like 'number', vim.go is corrupted by
      -- those overrides too. inst.user_winopts is the only reliable
      -- source of the user's pre-cc state.
      local cc = require('cc')
      local inst = cc.find_instance(bufnr)
      -- Skip transient appearances (mirror of the output-side guard):
      -- if a different window is the canonical prompt window, this winid
      -- is mid-layout flux and shouldn't claim the prompt baseline.
      if inst and inst.prompt_winid and inst.prompt_winid ~= winid then
        return
      end
      do
        local user_opts = inst and inst.user_winopts or nil
        if user_opts then
          winopts.save_table(winid, 'prompt', PROMPT_WIN_OPTS, user_opts)
        else
          winopts.save(winid, 'prompt', PROMPT_WIN_OPTS)
        end
      end
      -- Stash the winid where it's correct (current win is this prompt's
      -- window here). BufWinLeave's `nvim_get_current_win` would return
      -- the destination window instead, so we read this back there.
      vim.b[bufnr].cc_prompt_winid = winid
      vim.wo[winid].number = config.line_numbers and config.line_numbers.prompt or false
      vim.wo[winid].relativenumber = false
      vim.wo[winid].signcolumn = 'no'
      vim.wo[winid].wrap = config.wrap == nil or config.wrap.prompt ~= false
    end,
  })
  vim.api.nvim_create_autocmd('BufWinLeave', {
    group = group,
    buffer = bufnr,
    callback = function()
      local saved_winid = vim.b[bufnr].cc_prompt_winid
      vim.b[bufnr].cc_prompt_winid = nil
      if saved_winid and vim.api.nvim_win_is_valid(saved_winid) then
        winopts.restore(saved_winid, 'prompt', PROMPT_WIN_OPTS)
      end
    end,
  })
end

function Prompt:set_window(winid)
  self.winid = winid
end

--- Rename the prompt buffer (e.g. to reflect a session title). No-op on empty
--- input or if the buffer isn't yet created. Wrapped in pcall so a name
--- collision (E95) doesn't abort the caller.
---@param name string
function Prompt:set_buf_name(name)
  if not name or name == '' then return end
  self.buf_name = name
  if self.bufnr > 0 and vim.api.nvim_buf_is_valid(self.bufnr) then
    pcall(vim.api.nvim_buf_set_name, self.bufnr, name)
  end
end

--- Read current prompt buffer content as a single string.
---@return string
function Prompt:read()
  local bufnr = self:ensure_buffer()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, '\n')
end

--- Clear the prompt buffer.
function Prompt:clear()
  local bufnr = self:ensure_buffer()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
  -- nvim_buf_set_lines does not fire TextChanged, so the placeholder
  -- module's autocmd-driven rerender wouldn't catch this. Render directly.
  require('cc.placeholder').render(bufnr)
end

--- Whether the prompt has non-whitespace content.
function Prompt:has_content()
  local text = self:read()
  return text:match('%S') ~= nil
end

M.Prompt = Prompt
return M
