-- E2E: drive a real child nvim through the permission prompt with a
-- bidirectional fake claude. Verifies that pressing each key produces the
-- right control_response payload on the wire — including allow_always's
-- updatedPermissions and decisionClassification fields.
--
-- Architecture:
--   tests/fixtures/fake_claude_permission.sh emits init + can_use_tool, then
--   captures one line from its stdin (the SDK control_response) into
--   $CC_TEST_RESPONSE_FILE. The spec points providers.claude.cmd
--   at the fake, waits for the float, presses a key, then JSON-decodes the
--   captured response and asserts on its shape.

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local uv = vim.uv or vim.loop

local FAKE = h.repo_root .. '/tests/fixtures/fake_claude_permission.sh'

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      _G.child = nil
      _G.tmp_response = nil
    end,
    post_case = function()
      if _G.child then pcall(function() _G.child:close() end); _G.child = nil end
      if _G.tmp_response then pcall(os.remove, _G.tmp_response); _G.tmp_response = nil end
    end,
  },
})

--- Spawn a child + open cc with the bidirectional fake claude wired up.
--- Returns the temp file path the fake writes the captured response to.
---@param opts { omit_suggestions: boolean? }?
---@return string response_path
local function spawn_and_open(opts)
  opts = opts or {}
  local response_path = vim.fn.tempname() .. '.ndjson'
  _G.tmp_response = response_path

  local env = {
    CC_TEST_RESPONSE_FILE = response_path,
  }
  if opts.omit_suggestions then
    env.CC_TEST_OMIT_SUGGESTIONS = '1'
  end

  _G.child = h.spawn({ env = env })

  -- Configure cc to spawn the fake instead of real `claude`, then open.
  -- The fake reads CC_TEST_RESPONSE_FILE from its env — uv.spawn inherits
  -- env from the parent (the child nvim), which got it from spawn() above.
  _G.child:lua(([[
    require('cc').setup({
      providers = { claude = { cmd = %q, permission_mode = 'default' } },
    })
    require('cc').open()
  ]]):format(FAKE))

  return response_path
end

--- Wait until a floating window appears whose title contains "Permission".
--- The permission_prompt creates this float in response to the can_use_tool
--- request emitted by the fake on startup.
---@param child cc.E2EChild
---@param timeout_ms integer?
---@return integer? winid the float's winid in the child
local function wait_for_permission_float(child, timeout_ms)
  local found = child:wait_for(function(c)
    return c:lua([[
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative ~= '' then
          local title = cfg.title
          if type(title) == 'table' then title = title[1] and title[1][1] or '' end
          if type(title) == 'string' and title:find('Permission', 1, true) then
            return w
          end
        end
      end
      return false
    ]])
  end, timeout_ms or 4000)
  if not found then return nil end
  return child:lua([[
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' then
        local title = cfg.title
        if type(title) == 'table' then title = title[1] and title[1][1] or '' end
        if type(title) == 'string' and title:find('Permission', 1, true) then
          return w
        end
      end
    end
  ]])
end

--- Block until `path` exists and is non-empty, then read and JSON-decode the
--- single line in it. The fake writes one NDJSON line via `head -n 1 >`.
---@param path string
---@param timeout_ms integer?
---@return table msg
local function read_captured_response(path, timeout_ms)
  timeout_ms = timeout_ms or 4000
  local deadline = uv.hrtime() + timeout_ms * 1e6
  while uv.hrtime() < deadline do
    local st = uv.fs_stat(path)
    if st and st.size > 0 then break end
    vim.wait(25, function() return false end, nil, true)
  end
  local f = io.open(path, 'r')
  if not f then error('captured response file never written: ' .. path) end
  local line = f:read('*l') or ''
  f:close()
  if line == '' then error('captured response file is empty: ' .. path) end
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok then error('failed to decode captured response: ' .. line) end
  return decoded
end

T['allow_once (a) sends plain allow on the wire'] = function()
  local response_path = spawn_and_open()
  local float = wait_for_permission_float(_G.child)
  if not float then error('permission float never appeared') end
  _G.child:keys('a')

  local msg = read_captured_response(response_path)
  eq(msg.type, 'control_response')
  local body = msg.response.response
  eq(body.behavior, 'allow')
  eq(body.toolUseID, 'tu-test')
  eq(body.decisionClassification, 'user_temporary')
  -- Allow-once must NOT echo permission_suggestions back.
  eq(body.updatedPermissions, nil)
end

T['allow_always (A) echoes permission_suggestions back as updatedPermissions'] = function()
  local response_path = spawn_and_open()
  local float = wait_for_permission_float(_G.child)
  if not float then error('permission float never appeared') end
  _G.child:keys('A')

  local msg = read_captured_response(response_path)
  local body = msg.response.response
  eq(body.behavior, 'allow')
  eq(body.decisionClassification, 'user_permanent')
  eq(#body.updatedPermissions, 1)
  local upd = body.updatedPermissions[1]
  eq(upd.type, 'addRules')
  eq(upd.behavior, 'allow')
  eq(upd.destination, 'localSettings')
  eq(upd.rules[1].toolName, 'Bash')
  eq(upd.rules[1].ruleContent, 'ls:*')
end

T['allow_always synthesizes a tool-wide rule when CLI sent no suggestions'] = function()
  local response_path = spawn_and_open({ omit_suggestions = true })
  local float = wait_for_permission_float(_G.child)
  if not float then error('permission float never appeared') end
  _G.child:keys('A')

  local msg = read_captured_response(response_path)
  local body = msg.response.response
  eq(body.behavior, 'allow')
  eq(body.decisionClassification, 'user_permanent')
  eq(#body.updatedPermissions, 1)
  local upd = body.updatedPermissions[1]
  eq(upd.type, 'addRules')
  eq(upd.behavior, 'allow')
  eq(upd.destination, 'localSettings')
  eq(#upd.rules, 1)
  eq(upd.rules[1].toolName, 'Bash')
  -- ruleContent absent → matches the whole tool, like upstream Fallback.
  eq(upd.rules[1].ruleContent, nil)
end

T['deny (d) sends deny with user_reject'] = function()
  local response_path = spawn_and_open()
  local float = wait_for_permission_float(_G.child)
  if not float then error('permission float never appeared') end
  _G.child:keys('d')

  local msg = read_captured_response(response_path)
  local body = msg.response.response
  eq(body.behavior, 'deny')
  eq(body.decisionClassification, 'user_reject')
  eq(body.updatedPermissions, nil)
end

return T
