-- Classify transcript user-message strings that are actually synthetic
-- wrappers injected by Claude Code (task notifications, system reminders,
-- slash-command echoes, local-command output, etc.) instead of human input.
--
-- Live SDK streams can't reach render_user_turn with this content (router.lua
-- only routes tool_result blocks). The leak is historical replay: when
-- history.read_transcript sees `message.content` as a string, it would
-- otherwise unconditionally produce a `user_text` record and dump raw XML
-- into the output buffer as a User: turn.
--
-- Tag list mirrors Claude Code's ~/src/claude-code/src/constants/xml.ts.
-- Unknown kebab-case wrappers trigger a one-time vim.notify so we learn
-- about new tags as Claude Code adds them.

local M = {}

local KNOWN_TAGS = {
  ['task-notification'] = true,
  ['system-reminder'] = true,
  ['command-message'] = true,
  ['command-name'] = true,
  ['command-args'] = true,
  ['local-command-stdout'] = true,
  ['local-command-stderr'] = true,
  ['local-command-caveat'] = true,
  ['bash-input'] = true,
  ['bash-stdout'] = true,
  ['bash-stderr'] = true,
  ['teammate-message'] = true,
  ['channel-message'] = true,
  ['cross-session-message'] = true,
  ['ultraplan'] = true,
  ['remote-review'] = true,
  ['remote-review-progress'] = true,
  ['fork-boilerplate'] = true,
  ['tick'] = true,
}

local notified_unknown = {}

local function notify_unknown(tag)
  if notified_unknown[tag] then return end
  notified_unknown[tag] = true
  vim.schedule(function()
    vim.notify(
      string.format("cc.nvim: unrecognized synthetic wrapper '<%s>' in transcript — please report.", tag),
      vim.log.levels.INFO
    )
  end)
end

--- Reset the unknown-tag notification cache. Test-only.
function M._reset_notified()
  notified_unknown = {}
end

local function summarize(tag, body)
  if tag == 'task-notification' then
    local summary = body:match('<summary>(.-)</summary>')
    local status = body:match('<status>(.-)</status>')
    if summary and summary ~= '' then
      return 'task ' .. (status or 'event') .. ': ' .. summary
    end
    return 'task notification'
  elseif tag == 'system-reminder' then
    return 'system reminder'
  elseif tag == 'command-message' then
    local name = body:match('<command%-name>(.-)</command%-name>')
    local args = body:match('<command%-args>(.-)</command%-args>')
    if name and name ~= '' then
      if args and args ~= '' then
        return 'command: ' .. name .. ' ' .. args
      end
      return 'command: ' .. name
    end
    return 'command'
  elseif tag == 'local-command-stdout' or tag == 'local-command-stderr' then
    return 'local command output'
  elseif tag == 'local-command-caveat' then
    return 'local command caveat'
  end
  return (tag:gsub('-', ' '))
end

--- Classify a user-message string from a transcript record.
--- Returns ('text', cleaned) for human input (possibly with embedded
--- system-reminder blocks stripped) or ('notice', summary) for a synthetic
--- wrapper that should render as a one-line notice instead of a User turn.
---@param text string
---@return 'text'|'notice', string
function M.classify(text)
  if type(text) ~= 'string' or text == '' then
    return 'text', text or ''
  end

  -- Strip embedded <system-reminder> blocks (they wrap appended context, not
  -- the whole message). If only a reminder remains, surface it as a notice;
  -- otherwise render the surrounding human text normally.
  local stripped, n = text:gsub('<system%-reminder>.-</system%-reminder>%s*', '')
  if n > 0 then
    stripped = vim.trim(stripped)
    if stripped == '' then
      return 'notice', 'system reminder'
    end
    text = stripped
  end

  -- Detect a tag wrapping the entire message.
  local trimmed = vim.trim(text)
  local tag = trimmed:match('^<([%w%-]+)>')
  if tag then
    local closing = '</' .. tag .. '>'
    if trimmed:sub(-#closing) == closing then
      local open_len = #tag + 2
      local body = trimmed:sub(open_len + 1, -#closing - 1)
      if KNOWN_TAGS[tag] then
        return 'notice', summarize(tag, body)
      end
      -- Unknown wrapper: only treat as synthetic if kebab-case (hyphen
      -- present). Single-word tags (<div>, <svg>, <CustomElement>) are too
      -- risky to assume synthetic — could be legitimate user-pasted markup.
      if tag:find('-') then
        notify_unknown(tag)
        return 'notice', (tag:gsub('-', ' '))
      end
    end
  end

  return 'text', text
end

M._KNOWN_TAGS = KNOWN_TAGS

return M
