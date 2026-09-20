-- Shared requests and keyboard paths for real-window interactive tests.
-- `basic` marks the one-step happy path per flow; `before_cancel` marks
-- cases whose remote dismissal happens mid-flow.
local questions = {
  { question = 'Which color?', options = { { label = 'Red' }, { label = 'Blue' } } },
}
local multi_questions = {
  { question = 'Which colors?', multiSelect = true,
    options = { { label = 'Red' }, { label = 'Blue' }, { label = 'Green' } } },
  { question = 'Continue?', options = { { label = 'Yes' } } },
}
local function tool(name, input)
  return { subtype = 'can_use_tool', tool_name = name, tool_use_id = 'tool-1', input = input or {} }
end
local function allow(input)
  return { behavior = 'allow', updatedInput = input, toolUseID = 'tool-1' }
end
local function deny(message)
  return { behavior = 'deny', message = message, toolUseID = 'tool-1' }
end
return {
  { name = 'ExitPlanMode', basic = true, request = tool('ExitPlanMode', { plan = 'Review this plan' }),
    keys = { '<CR>' }, response = allow({ plan = 'Review this plan' }) },
  { name = 'AskUserQuestion', basic = true, request = tool('AskUserQuestion', { questions = questions }),
    keys = { 'j', '<CR>' }, response = allow({ questions = questions, answers = { ['Which color?'] = 'Blue' } }) },
  { name = 'elicitation', basic = true, request = { subtype = 'elicitation', message = 'Continue?' },
    keys = { '<CR>' }, response = { action = 'accept', content = {} } },
  { name = 'ExitPlanMode rejection input', request = tool('ExitPlanMode'),
    before_cancel = { 'j', '<CR>' }, keys = { 'j', '<CR>', 'Please revise', '<CR>' },
    response = deny('Please revise') },
  { name = 'ExitPlanMode keyboard cancel', request = tool('ExitPlanMode'),
    before_cancel = { 'q' }, keys = { 'q', '<Esc>' }, response = deny('User rejected plan via cc.nvim') },
  { name = 'ExitPlanMode edit', request = tool('ExitPlanMode'), keys = { 'jj', '<CR>' },
    response = deny('User wants to edit the plan before approving') },
  { name = 'AskUserQuestion other input', request = tool('AskUserQuestion', { questions = questions }),
    before_cancel = { 'jj', '<CR>' }, keys = { 'jj', '<CR>', 'Purple', '<CR>' },
    response = allow({ questions = questions, answers = { ['Which color?'] = 'Purple' } }) },
  { name = 'AskUserQuestion keyboard cancel', request = tool('AskUserQuestion', { questions = questions }),
    keys = { '<Esc>' }, response = allow({ questions = questions, answers = { ['Which color?'] = '' } }) },
  { name = 'AskUserQuestion other cancel', request = tool('AskUserQuestion', { questions = questions }),
    keys = { 'jj', '<CR>', '<Esc>' }, response = allow({ questions = questions, answers = { ['Which color?'] = '' } }) },
  { name = 'AskUserQuestion multi intermediate', request = tool('AskUserQuestion', { questions = multi_questions }),
    before_cancel = { '<CR>' }, keys = { '<CR>', '<CR>', 'j', '<CR>', '<CR>' },
    response = allow({ questions = multi_questions, answers = { ['Which colors?'] = 'Blue, Red', ['Continue?'] = 'Yes' } }) },
  { name = 'AskUserQuestion multi other input', request = tool('AskUserQuestion', { questions = multi_questions }),
    before_cancel = { 'G', '<CR>' }, keys = { 'G', '<CR>', 'Purple', '<CR>', 'q', '<CR>' },
    response = allow({ questions = multi_questions, answers = { ['Which colors?'] = 'Purple', ['Continue?'] = 'Yes' } }) },
  { name = 'AskUserQuestion second question', request = tool('AskUserQuestion', { questions = multi_questions }),
    before_cancel = { 'q' }, keys = { 'q', '<CR>' },
    response = allow({ questions = multi_questions, answers = { ['Which colors?'] = '', ['Continue?'] = 'Yes' } }) },
  { name = 'elicitation fields', request = { subtype = 'elicitation', message = 'Details',
      requested_schema = { properties = { first = {}, second = {} } } },
    before_cancel = {}, keys = { 'One', '<CR>', 'Two', '<CR>' },
    response = { action = 'accept', content = { first = 'One', second = 'Two' } } },
  { name = 'elicitation second field', request = { subtype = 'elicitation', message = 'Details',
      requested_schema = { properties = { first = {}, second = {} } } },
    before_cancel = { 'One', '<CR>' }, keys = { 'One', '<CR>', '<Esc>' },
    response = { action = 'cancel' } },
  { name = 'elicitation keyboard cancel', request = { subtype = 'elicitation', message = 'Continue?' },
    keys = { 'q' }, response = { action = 'cancel' } },
  { name = 'elicitation URL cancel', request = { subtype = 'elicitation', message = 'Open this',
      mode = 'url', url = 'https://example.com' },
    before_cancel = {}, keys = { '<Down>', '<CR>' }, response = { action = 'cancel' } },
}
