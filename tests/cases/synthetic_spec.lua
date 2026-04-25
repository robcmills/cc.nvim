-- Tests for cc.synthetic: classifying transcript user-message strings as
-- either real user text or synthetic Claude Code wrappers (task notifications,
-- system reminders, slash-command echoes, etc.).
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

local function classify(child, text)
  child.lua(string.format([[
    require('cc.synthetic')._reset_notified()
    local kind, payload = require('cc.synthetic').classify(%q)
    _G._kind = kind
    _G._payload = payload
  ]], text))
  return child.lua_get('_G._kind'), child.lua_get('_G._payload')
end

-- ---------------------------------------------------------------------------
-- classify
-- ---------------------------------------------------------------------------
T['classify'] = MiniTest.new_set()

T['classify']['plain user text passes through'] = function()
  local kind, payload = classify(_G.child, 'hello, world')
  eq(kind, 'text')
  eq(payload, 'hello, world')
end

T['classify']['empty string is text'] = function()
  local kind, payload = classify(_G.child, '')
  eq(kind, 'text')
  eq(payload, '')
end

T['classify']['task-notification becomes notice with summary'] = function()
  local body = '<task-notification>'
    .. '<task-id>abc</task-id>'
    .. '<status>completed</status>'
    .. '<summary>Background command "Locate options.txt" completed (exit code 0)</summary>'
    .. '</task-notification>'
  local kind, payload = classify(_G.child, body)
  eq(kind, 'notice')
  eq(payload, 'task completed: Background command "Locate options.txt" completed (exit code 0)')
end

T['classify']['system-reminder full wrap becomes notice'] = function()
  local kind, payload = classify(_G.child, '<system-reminder>some hint here</system-reminder>')
  eq(kind, 'notice')
  eq(payload, 'system reminder')
end

T['classify']['command-message produces command notice'] = function()
  local body = '<command-message><command-name>/loop</command-name><command-args>5m /foo</command-args></command-message>'
  local kind, payload = classify(_G.child, body)
  eq(kind, 'notice')
  eq(payload, 'command: /loop 5m /foo')
end

T['classify']['embedded system-reminder is stripped from real text'] = function()
  local body = 'real user text\n<system-reminder>injected context</system-reminder>'
  local kind, payload = classify(_G.child, body)
  eq(kind, 'text')
  eq(payload, 'real user text')
end

T['classify']['only embedded system-reminder yields notice'] = function()
  local body = '<system-reminder>only this</system-reminder>'
  local kind, _ = classify(_G.child, body)
  eq(kind, 'notice')
end

T['classify']['unknown kebab-case wrapper notifies and becomes notice'] = function()
  _G.child.lua([[
    require('cc.synthetic')._reset_notified()
    _G._notifications = {}
    vim.notify = function(msg, level) table.insert(_G._notifications, msg) end
    local kind, payload = require('cc.synthetic').classify('<future-thing>data</future-thing>')
    _G._kind = kind
    _G._payload = payload
    vim.wait(50, function() return false end)
  ]])
  eq(_G.child.lua_get('_G._kind'), 'notice')
  eq(_G.child.lua_get('_G._payload'), 'future thing')
  local notifications = _G.child.lua_get('_G._notifications')
  eq(#notifications, 1)
  if not notifications[1]:find('future%-thing') then
    error('expected notification to mention <future-thing>, got: ' .. notifications[1])
  end
end

T['classify']['unknown wrapper notifies only once per process'] = function()
  _G.child.lua([[
    require('cc.synthetic')._reset_notified()
    _G._notifications = {}
    vim.notify = function(msg, level) table.insert(_G._notifications, msg) end
    local s = require('cc.synthetic')
    s.classify('<weird-thing>a</weird-thing>')
    s.classify('<weird-thing>b</weird-thing>')
    s.classify('<weird-thing>c</weird-thing>')
    vim.wait(50, function() return false end)
  ]])
  eq(#_G.child.lua_get('_G._notifications'), 1)
end

T['classify']['single-word unknown tag is treated as user text'] = function()
  -- <div>...</div> from a paste must NOT be misclassified as synthetic.
  local kind, payload = classify(_G.child, '<div>hello</div>')
  eq(kind, 'text')
  eq(payload, '<div>hello</div>')
end

T['classify']['inline mention of synthetic tag is not synthetic'] = function()
  -- A user asking about a tag inline (no full-message wrap) stays as text.
  local kind, _ = classify(_G.child, 'what does <task-notification> mean?')
  eq(kind, 'text')
end

T['classify']['mismatched open/close stays as text'] = function()
  local kind, _ = classify(_G.child, '<task-notification>oops</something-else>')
  eq(kind, 'text')
end

-- ---------------------------------------------------------------------------
-- read_transcript integration
-- ---------------------------------------------------------------------------
T['read_transcript'] = MiniTest.new_set()

T['read_transcript']['classifies task-notification user record as synthetic_notice'] = function()
  _G.child.lua([==[
    local tmp = vim.fn.tempname() .. '.jsonl'
    local jsonl_lines = {
      vim.json.encode({
        type = 'user',
        message = { role = 'user', content = 'hello there' },
      }),
      vim.json.encode({
        type = 'user',
        message = {
          role = 'user',
          content = '<task-notification><status>completed</status><summary>did the thing</summary></task-notification>',
        },
      }),
    }
    vim.fn.writefile(jsonl_lines, tmp)
    _G._records = require('cc.history').read_transcript(tmp)
    vim.fn.delete(tmp)
  ]==])
  local recs = _G.child.lua_get('_G._records')
  eq(#recs, 2)
  eq(recs[1].type, 'user_text')
  eq(recs[1].text, 'hello there')
  eq(recs[2].type, 'synthetic_notice')
  eq(recs[2].text, 'task completed: did the thing')
end

T['read_transcript']['render_historical_record draws synthetic_notice as a notice line'] = function()
  _G.child.lua([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    output:ensure_buffer()
    vim.api.nvim_set_current_buf(output.bufnr)
    output:render_historical_record({ type = 'synthetic_notice', text = 'task completed: did the thing' })
    _G._test_bufnr = output.bufnr
  ]==])
  local lines = helpers.get_buffer_lines(_G.child)
  local found = false
  for _, l in ipairs(lines) do
    if l:match('task completed: did the thing') then found = true; break end
  end
  eq(found, true)
  -- And no User: turn was created for it.
  local user_turn = false
  for _, l in ipairs(lines) do
    if l:match('^User:') then user_turn = true; break end
  end
  eq(user_turn, false)
end

return T
