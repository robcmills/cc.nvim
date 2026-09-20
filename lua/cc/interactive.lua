-- Specialized handlers for interactive CC features:
-- AskUserQuestion, EnterPlanMode, ExitPlanMode, MCP elicitation.
-- Each receives the permission/control request, collects user input via
-- Neovim UI, and writes a control_response back through the process.

local M = {}

--- Send a success control_response.
---@param process cc.Process
---@param request_id string
---@param response_body table
---@param instance cc.Instance?
local function respond_success(process, request_id, response_body, instance)
  process:write({
    type = 'control_response',
    response = {
      request_id = request_id,
      subtype = 'success',
      response = response_body,
    },
  })
  if instance then
    instance.awaiting_permission = false
    instance.awaiting_input = false
    require('cc.statusline').refresh(instance)
  end
end

---@class cc.InteractivePrompt
---@field dismiss fun() Close the current step without responding or changing instance state.
---@field select fun(items: any[], opts: table, callback: function)
---@field input fun(opts: table, callback: function)
---@field respond fun(body: table)
---@field close_preview fun()?

--- One lifetime spans every picker/input in a request. Guard callbacks as well
--- as writes so a queued local choice cannot advance a remotely answered flow.
---@param process cc.Process
---@param request_id string
---@param instance cc.Instance?
---@param on_response fun()?
---@return cc.InteractivePrompt
local function new_prompt(process, request_id, instance, on_response)
  local done = false
  ---@type cc.PickerHandle?
  local current
  ---@type cc.InteractivePrompt
  local prompt = {}
  local function close()
    if current then current.dismiss() end
    if prompt.close_preview then prompt.close_preview() end
  end
  function prompt.dismiss()
    if done then return end
    done = true
    close()
  end
  function prompt.respond(body)
    if done then return end
    done = true
    close()
    if on_response then on_response() end
    respond_success(process, request_id, body, instance)
  end
  function prompt.select(items, opts, callback)
    if done then return end
    current = require('cc.picker').select(items, opts, function(...)
      if not done then callback(...) end
    end)
  end
  function prompt.input(opts, callback)
    if done then return end
    current = require('cc.picker').input(opts, function(...)
      if not done then callback(...) end
    end)
  end
  return prompt
end

-- ---------------------------------------------------------------------------
-- EnterPlanMode: auto-approve, show notice.
-- ---------------------------------------------------------------------------
---@param process cc.Process
---@param output cc.Output
---@param request_id string
---@param req table can_use_tool request payload
---@param instance cc.Instance?
---@param on_response fun()? Called before writing a local response.
---@return cc.InteractivePrompt
function M.handle_enter_plan_mode(process, output, request_id, req, instance, on_response)
  local prompt = new_prompt(process, request_id, instance, on_response)
  output:render_notice('Plan Mode')
  local input = req.input or {}
  if input.plan_file_path then
    pcall(function() require('cc')._set_last_plan_file(input.plan_file_path, output.bufnr) end)
  end
  prompt.respond({
    behavior = 'allow',
    updatedInput = input,
    toolUseID = req.tool_use_id,
  })
  return prompt
end

-- ---------------------------------------------------------------------------
-- ExitPlanMode: show the plan, ask Approve/Reject/Edit.
-- ---------------------------------------------------------------------------

---@param plan_text string
---@return integer bufnr, integer winid
local function open_plan_float(plan_text)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].bufhidden = 'wipe'
  local lines = vim.split(plan_text, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' Plan for review ',
    title_pos = 'center',
  })
  return bufnr, winid
end

---@param process cc.Process
---@param output cc.Output
---@param request_id string
---@param req table
---@param instance cc.Instance?
---@param on_response fun()? Called before writing a local response.
---@return cc.InteractivePrompt
function M.handle_exit_plan_mode(process, output, request_id, req, instance, on_response)
  local prompt = new_prompt(process, request_id, instance, on_response)
  local input = req.input or {}
  local plan_text = input.plan or '(no plan content)'
  local plan_file = input.plan_file_path
  if plan_file then
    pcall(function() require('cc')._set_last_plan_file(plan_file, output.bufnr) end)
  end

  local _, float_winid = open_plan_float(plan_text)

  local function close_float()
    if float_winid and vim.api.nvim_win_is_valid(float_winid) then
      pcall(vim.api.nvim_win_close, float_winid, true)
    end
  end

  prompt.close_preview = close_float

  prompt.select(
    { 'Approve plan', 'Reject plan', 'Edit plan' },
    { prompt = 'ExitPlanMode: ' },
    function(choice)
      close_float()
      if not choice or choice == 'Reject plan' then
        prompt.input({ prompt = 'Reason (optional): ' }, function(reason)
          output:render_notice('Plan rejected')
          prompt.respond({
            behavior = 'deny',
            message = reason and reason ~= '' and reason or 'User rejected plan via cc.nvim',
            toolUseID = req.tool_use_id,
          })
        end)
      elseif choice == 'Approve plan' then
        output:render_notice('Plan approved')
        prompt.respond({
          behavior = 'allow',
          updatedInput = input,
          toolUseID = req.tool_use_id,
        })
      elseif choice == 'Edit plan' then
        if plan_file and plan_file ~= '' then
          -- Open the plan file in a split; user edits and re-runs.
          vim.cmd('tabedit ' .. vim.fn.fnameescape(plan_file))
          output:render_notice('Plan being edited; ask Claude to ExitPlanMode again when ready')
        else
          output:render_notice('No plan_file_path provided; cannot edit')
        end
        prompt.respond({
          behavior = 'deny',
          message = 'User wants to edit the plan before approving',
          toolUseID = req.tool_use_id,
        })
      end
    end
  )
  return prompt
end

-- ---------------------------------------------------------------------------
-- AskUserQuestion: multi-question picker.
-- ---------------------------------------------------------------------------

---@param prompt cc.InteractivePrompt
---@param question table { question, header, options, multiSelect }
---@param on_answer fun(answer: string)
local function ask_single_question(prompt, question, on_answer)
  local options = question.options or {}
  local labels = {}
  for _, opt in ipairs(options) do
    table.insert(labels, opt.label)
  end
  -- Always offer "Other" as a free-text escape hatch (per CC's own convention).
  table.insert(labels, 'Other (type)')

  if question.multiSelect then
    -- Simple multi-select: run prompt.select repeatedly, collecting picks.
    local selected = {}
    local function step()
      local remaining = {}
      for _, l in ipairs(labels) do
        if l ~= 'Other (type)' and not selected[l] then
          table.insert(remaining, l)
        end
      end
      if #remaining == 0 then
        on_answer(M._join_selected(selected))
        return
      end
      table.insert(remaining, '-- done --')
      table.insert(remaining, 'Other (type)')
      prompt.select(remaining, { prompt = question.question .. ' (multi)' }, function(choice)
        if not choice or choice == '-- done --' then
          on_answer(M._join_selected(selected))
          return
        end
        if choice == 'Other (type)' then
          prompt.input({ prompt = 'Enter value: ' }, function(text)
            if text and text ~= '' then selected[text] = true end
            step()
          end)
          return
        end
        selected[choice] = true
        step()
      end)
    end
    step()
  else
    prompt.select(labels, { prompt = question.question }, function(choice)
      if not choice then
        on_answer('')
        return
      end
      if choice == 'Other (type)' then
        prompt.input({ prompt = 'Enter answer: ' }, function(text)
          on_answer(text or '')
        end)
        return
      end
      on_answer(choice)
    end)
  end
end

---@param selected table<string, boolean>
---@return string
function M._join_selected(selected)
  local list = {}
  for k, _ in pairs(selected) do table.insert(list, k) end
  table.sort(list)
  return table.concat(list, ', ')
end

---@param process cc.Process
---@param output cc.Output
---@param request_id string
---@param req table
---@param instance cc.Instance?
---@param on_response fun()? Called before writing a local response.
---@return cc.InteractivePrompt
function M.handle_ask_user_question(process, output, request_id, req, instance, on_response)
  local prompt = new_prompt(process, request_id, instance, on_response)
  local input = req.input or {}
  local questions = input.questions or {}
  local answers = {}

  -- Render a compact summary of the questions in the output buffer.
  for _, q in ipairs(questions) do
    output:render_notice('Question: ' .. (q.question or ''))
  end

  local function finish()
    prompt.respond({
      behavior = 'allow',
      updatedInput = {
        questions = questions,
        answers = answers,
      },
      toolUseID = req.tool_use_id,
    })
  end

  local i = 1
  local function ask_next()
    if i > #questions then
      finish()
      return
    end
    local q = questions[i]
    ask_single_question(prompt, q, function(answer)
      answers[q.question] = answer
      output:render_notice('Answer: ' .. answer)
      i = i + 1
      ask_next()
    end)
  end
  ask_next()
  return prompt
end

-- ---------------------------------------------------------------------------
-- MCP Elicitation (subtype = 'elicitation')
-- ---------------------------------------------------------------------------

---@param process cc.Process
---@param output cc.Output
---@param request_id string
---@param req table elicitation request
---@param instance cc.Instance?
---@param on_response fun()? Called before writing a local response.
---@return cc.InteractivePrompt
function M.handle_elicitation(process, output, request_id, req, instance, on_response)
  local prompt = new_prompt(process, request_id, instance, on_response)
  local message = req.message or '(no message)'
  local mode = req.mode
  local url = req.url

  output:render_notice('MCP request: ' .. message)

  if mode == 'url' and url and url ~= '' then
    prompt.select(
      { 'Open in browser', 'Cancel' },
      { prompt = message .. '\nURL: ' .. url },
      function(choice)
        if choice == 'Open in browser' then
          pcall(vim.ui.open, url)
          prompt.respond({ action = 'accept', content = {} })
        else
          prompt.respond({ action = 'cancel' })
        end
      end
    )
    return prompt
  end

  -- Form mode: collect values for each property in requested_schema.
  local schema = req.requested_schema
  if type(schema) == 'table' and type(schema.properties) == 'table' then
    local content = {}
    local keys = {}
    for k, _ in pairs(schema.properties) do table.insert(keys, k) end
    table.sort(keys)
    local i = 1
    local function step()
      if i > #keys then
        prompt.respond({ action = 'accept', content = content })
        return
      end
      local key = keys[i]
      local prop = schema.properties[key]
      local label = (prop and prop.description) or key
      prompt.input({ prompt = label .. ': ' }, function(text)
        if text == nil then
          prompt.respond({ action = 'cancel' })
          return
        end
        content[key] = text
        i = i + 1
        step()
      end)
    end
    step()
    return prompt
  end

  -- No schema, just a confirm/cancel message.
  prompt.select(
    { 'Accept', 'Cancel' },
    { prompt = message },
    function(choice)
      if choice == 'Accept' then
        prompt.respond({ action = 'accept', content = {} })
      else
        prompt.respond({ action = 'cancel' })
      end
    end
  )
  return prompt
end

return M
