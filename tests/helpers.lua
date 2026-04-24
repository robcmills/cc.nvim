-- Test helpers for cc.nvim — child process setup, fixture loading, assertions.
local M = {}

local MiniTest = require('mini.test')

--- Absolute paths resolved from this file's location.
M.this_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
M.repo_root = vim.fn.fnamemodify(M.this_dir, ':h')
M.fixtures_dir = M.this_dir .. '/fixtures/jsonl'
M.ndjson_fixtures_dir = M.this_dir .. '/fixtures/ndjson'

--- Create a new mini.test child process with cc.nvim loaded.
--- Uses the same init file as the parent (minimal or rob) unless overridden.
---@param init_file? string path to init file
---@return table child mini.test child
function M.new_child(init_file)
  init_file = init_file or vim.g.cc_test_init or (M.this_dir .. '/minimal_init.lua')
  local child = MiniTest.new_child_neovim()
  child.restart({ '-u', init_file })
  -- Wait for startup to settle
  child.lua('vim.wait(100, function() return false end)')
  return child
end

--- Load a JSONL fixture through cc.nvim's history transcript reader.
--- Returns the parsed records as a Lua table in the child process.
---@param child table mini.test child
---@param fixture_name string e.g. 'simple_text' (without .jsonl)
---@return table[] records
function M.load_fixture_records(child, fixture_name)
  local fixture_path = M.fixtures_dir .. '/' .. fixture_name .. '.jsonl'
  child.lua(string.format([[
    _G._test_fixture_path = %q
    _G._test_records = require('cc.history').read_transcript(_G._test_fixture_path)
  ]], fixture_path))
  return child.lua_get('_G._test_records')
end

--- Set up a cc.nvim Output instance in the child and render fixture records.
--- Returns the output buffer number.
---@param child table mini.test child
---@param fixture_name string
---@param opts table? optional cc.config overrides (e.g. { tool_icons = {...} })
---@return integer bufnr
function M.render_fixture(child, fixture_name, opts)
  local fixture_path = M.fixtures_dir .. '/' .. fixture_name .. '.jsonl'
  local opts_str = vim.inspect(opts or {})
  child.lua(string.format([==[
    local history = require('cc.history')
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup(%s)

    -- Create a session (required by Output.new)
    local session = Session.new()

    -- Create output instance with proper initialization
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()

    -- Show it in the current window so fold/syntax/etc work
    vim.api.nvim_set_current_buf(bufnr)

    -- Load and render transcript records
    local records = history.read_transcript(%q)
    for _, rec in ipairs(records) do
      output:render_historical_record(rec)
    end

    -- Store references for assertions
    _G._test_bufnr = bufnr
    _G._test_output = output
  ]==], opts_str, fixture_path))
  return child.lua_get('_G._test_bufnr')
end

--- Get all lines from the output buffer in the child.
---@param child table
---@return string[]
function M.get_buffer_lines(child)
  return child.lua_get('vim.api.nvim_buf_get_lines(_G._test_bufnr, 0, -1, false)')
end

--- Get fold levels for all lines in the output buffer.
---@param child table
---@return table<integer, string|integer> map of line number -> fold level
function M.get_fold_levels(child)
  child.lua([==[
    local state = require('cc.output')._buf_state[_G._test_bufnr]
    _G._test_fold_levels = state and state.fold_levels or {}
  ]==])
  return child.lua_get('_G._test_fold_levels')
end

--- Get all extmarks from a named namespace in the output buffer.
---@param child table
---@param ns_name string e.g. 'cc.carets'
---@return table[] extmarks
function M.get_extmarks(child, ns_name)
  child.lua(string.format([==[
    local ns = vim.api.nvim_get_namespaces()[%q]
    if not ns then _G._test_extmarks = {}; return end
    local marks = vim.api.nvim_buf_get_extmarks(_G._test_bufnr, ns, 0, -1, { details = true })
    local result = {}
    for _, m in ipairs(marks) do
      table.insert(result, {
        id = m[1],
        row = m[2],
        col = m[3],
        details = m[4],
      })
    end
    _G._test_extmarks = result
  ]==], ns_name))
  return child.lua_get('_G._test_extmarks')
end

--- Get the syntax highlight group at a specific position.
--- When trans=true (default), resolves through links (CcUser -> Function).
--- When trans=false, returns the original syntax group name (CcUser).
---@param child table
---@param row integer 1-based
---@param col integer 1-based
---@param trans? boolean resolve through linked groups (default false)
---@return string hl_group
function M.get_hl_at(child, row, col, trans)
  local trans_flag = trans and 'true' or 'false'
  child.lua(string.format([==[
    local id = vim.fn.synID(%d, %d, true)
    if %s then
      _G._test_hl = vim.fn.synIDattr(vim.fn.synIDtrans(id), 'name')
    else
      _G._test_hl = vim.fn.synIDattr(id, 'name')
    end
  ]==], row, col, trans_flag))
  return child.lua_get('_G._test_hl')
end

--- Get the full syntax stack at a position (all matching groups, topmost last).
---@param child table
---@param row integer 1-based
---@param col integer 1-based
---@return string[] group names
function M.get_syn_stack(child, row, col)
  child.lua(string.format([==[
    local ids = vim.fn.synstack(%d, %d)
    local names = {}
    for _, id in ipairs(ids) do
      table.insert(names, vim.fn.synIDattr(id, 'name'))
    end
    _G._test_syn_stack = names
  ]==], row, col))
  return child.lua_get('_G._test_syn_stack')
end

--- Produce a Layer-C visual dump of the output buffer.
--- Format:
---   cc-output | N lines | foldlevel=L
---   ─────────────
---    1 [HlGroup  ]  line text here
---    2 [         ]  more text
---       extmark row=1 col=0 virt_text=[('▾ ', 'CcCaret')]
---   ─────────────
---@param child table
---@return string dump
function M.visual_dump(child)
  -- Execute the dump logic in the child, store result in a global
  child.lua([==[
    local bufnr = _G._test_bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local state = require('cc.output')._buf_state[bufnr]
    local fold_levels = state and state.fold_levels or {}

    local foldlevel = 1
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        foldlevel = vim.wo[win].foldlevel
        break
      end
    end

    local parts = {}
    local sep = string.rep('-', 60)
    table.insert(parts, string.format('cc-output | %d lines | foldlevel=%d', #lines, foldlevel))
    table.insert(parts, sep)

    local caret_ns = vim.api.nvim_get_namespaces()['cc.carets']
    local caret_marks = {}
    if caret_ns then
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, caret_ns, 0, -1, { details = true })) do
        caret_marks[m[2]] = m[4]
      end
    end

    for i, line in ipairs(lines) do
      local hl = ''
      if #line > 0 then
        local col = line:find('%S')
        if col then
          local id = vim.fn.synID(i, col, true)
          hl = vim.fn.synIDattr(id, 'name')
        end
      end

      table.insert(parts, string.format('%3d [%-12s] %s', i, hl ~= '' and hl or '', line))

      local mark = caret_marks[i - 1]
      if mark and mark.virt_text then
        local vt_parts = {}
        for _, vt in ipairs(mark.virt_text) do
          table.insert(vt_parts, string.format("('%s', '%s')", vt[1], vt[2] or ''))
        end
        table.insert(parts, string.format('      extmark row=%d virt_text=[%s]', i - 1, table.concat(vt_parts, ', ')))
      end
    end

    table.insert(parts, sep)
    _G._test_visual_dump = table.concat(parts, '\n')
  ]==])
  return child.lua_get('_G._test_visual_dump')
end

--- Feed an NDJSON fixture through parser -> router -> output in the child.
--- This simulates the live streaming path (process.lua -> parser -> router -> output)
--- without spawning a subprocess. Tests the full streaming code path.
---@param child table mini.test child
---@param fixture_name string e.g. 'simple_text' (without .ndjson)
---@param opts table? optional cc.config overrides (e.g. { show_thinking = true })
---@return integer bufnr
function M.replay_streaming(child, fixture_name, opts)
  local fixture_path = M.ndjson_fixtures_dir .. '/' .. fixture_name .. '.ndjson'
  local opts_str = vim.inspect(opts or {})
  child.lua(string.format([==[
    local Parser = require('cc.parser')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup(%s)

    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    -- Mock process with no-op write (needed for control_request messages)
    local mock_process = {
      write = function() end,
      is_alive = function() return false end,
    }
    local router = Router.new({ session = session, output = output, process = mock_process })
    local parser = Parser.new()

    -- Read fixture and feed each line through the streaming pipeline
    local lines = vim.fn.readfile(%q)
    for _, line in ipairs(lines) do
      local messages = parser:feed(line .. '\n')
      for _, msg in ipairs(messages) do
        router:dispatch(msg)
      end
    end

    _G._test_bufnr = bufnr
    _G._test_output = output
    _G._test_session = session
    _G._test_router = router
  ]==], opts_str, fixture_path))
  return child.lua_get('_G._test_bufnr')
end

--- Get session state from the child after streaming replay.
---@param child table
---@return table session fields
function M.get_session_state(child)
  child.lua([==[
    local s = _G._test_session
    _G._test_session_state = {
      id = s.id,
      model = s.model,
      cost_usd = s.cost_usd,
      input_tokens = s.input_tokens,
      output_tokens = s.output_tokens,
      is_streaming = s.is_streaming,
      turn_active = s.turn_active,
      turn_count = #s.turns,
    }
  ]==])
  return child.lua_get('_G._test_session_state')
end

return M
