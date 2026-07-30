local M = {}

---@class cc.Config
local defaults = {
  -- Auto-rename: on the first prompt of a new session, ask the active
  -- provider for a short descriptive title and apply it via `/rename`.
  -- Skipped on resumed sessions (those already have a name) and on fixtures.
  --   prompt: template sent to the naming command. `${prompt}` is substituted
  --     with the user's first prompt text. Override to change output style
  --     (e.g. CamelCase, sentence case, language, length).
  --   Naming models are configured with
  --   providers.<provider>.auto_rename_model.
  --   timeout_ms: kill the rename subprocess if it has not exited by then.
  --   validate: function(raw_output) -> string | nil. Sanitizes / validates
  --     the model's stdout before it is applied. Return nil to reject.
  --     nil here uses the built-in sanitizer: trim, strip surrounding
  --     quotes, drop trailing lines, cap at 64 chars.
  auto_rename = {
    enabled = true,
    -- Display-only title while the rename subprocess is in flight.
    -- Set to false or '' to disable.
    placeholder = 'auto-generating-name...',
    prompt = 'Generate a very short, descriptive kebab-case name (2-5 hyphenated lowercase words) for this user prompt. Return only the name — no commentary, no quotes, no trailing punctuation.\n\nPrompt: ${prompt}',
    timeout_ms = 30000,
    validate = nil,
  },

  -- Folding: 0=minimal, 1=summaries, 2=inputs, 3=all.
  default_fold_level = 2,

  -- function(info) -> string; nil uses output.default_foldtext.
  foldtext = nil,

  -- Highlight overrides for cc-owned groups.
  highlights = {
    fold = nil, -- any nvim_set_hl spec, e.g. { fg, bg, italic, link, ... }
  },

  -- Maximum transcript records rendered when resuming.
  history_max_records = 500,

  keymaps = {
    clear_prompt = '<C-l>',
    cycle_permission_mode = '<S-Tab>',
    goto_output = 'go',
    goto_prompt = 'gp',
    interrupt = '<C-c>',
    submit = '<CR>',
  },

  layout = 'horizontal', -- 'horizontal' | 'vertical'

  line_numbers = {
    output = false,
    prompt = false,
  },

  markdown_highlight = {
    agent = true,
    user = true,
  },

  max_tool_result_lines = 50,

  prompt_height = 10,

  -- Set equal to prompt_height to disable automatic prompt growth.
  prompt_max_height = 30,

  -- Set to false or '' to disable the empty-prompt virtual text.
  prompt_placeholder = 'Write prompt here. Press <Enter> in normal mode to submit.',

  -- Active provider for new and resumed sessions.
  provider = 'claude', -- 'claude' | 'codex'

  providers = {
    claude = {
      auto_rename_model = 'haiku',
      cmd = 'claude',
      effort = 'medium', -- 'low'|'medium'|'high'|'xhigh'|'max'|'auto'
      extra_args = {},
      model = 'fable',
      permission_mode = nil, -- nil | 'default' | 'acceptEdits' | 'plan' | 'dontAsk' | 'bypassPermissions' | 'auto'
    },
    codex = {
      approval_policy = nil, -- nil | 'untrusted' | 'on-request' | 'never'
      auto_rename_model = 'gpt-5.6-luna',
      cmd = 'codex',
      effort = 'medium', -- 'low'|'medium'|'high'|'xhigh'|'max'|'auto'
      extra_args = {}, -- appended to `codex app-server`
      model = 'gpt-5.6-sol',
      sandbox = nil, -- nil | 'read-only' | 'workspace-write' | 'danger-full-access'
    },
  },

  show_thinking = true,

  show_turn_cost = true,

  -- Set to false to suppress the new-session splash.
  splash = true,

  -- Streaming output is coalesced to one buffer update per interval. Markdown
  -- highlighting is throttled independently because reparsing a growing prose
  -- block is substantially more expensive than appending its text.
  streaming = {
    render_interval_ms = 33, -- 10–1000ms; default is ~30 FPS
    markdown_hz = 5, -- 0.5–60Hz; negative = highlight only at block completion
  },

  statusline = {
    -- nil derives from the model ([1m] → 1,000,000; otherwise 200,000).
    context_window = nil,
    enabled = true,
    format = nil, -- function(state) -> Neovim statusline string
    spinner = {
      frames = nil,
      frames_nerdfont = {
        '\xef\x89\x94',
        '\xef\x89\x91',
        '\xef\x89\x92',
        '\xef\x89\x93',
      },
      frames_unicode = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
      interval_ms = 500,
      use_nerdfont = nil,
    },
    model_icons = {
      -- Set claude/codex to a string (or '' to hide) to override the
      -- provider-aware defaults.
      use_nerdfont = nil,
    },
    tokens_icon = 'τ',
  },

  tool_icons = {
    default = nil,
    icons = {},
    use_nerdfont = nil,
  },

  -- function(tool_name, input) -> string | nil
  tool_input_format = nil,

  -- function(result) -> string | nil
  turn_cost_format = nil,

  wrap = {
    output = true,
    prompt = true,
  },
}

M.options = vim.deepcopy(defaults)

local function finite_number(value)
  return type(value) == 'number'
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function warn_invalid(path, value, fallback, expected)
  vim.notify(
    string.format(
      'cc.nvim: invalid %s=%s; expected %s. Using default %s.',
      path, vim.inspect(value), expected, tostring(fallback)
    ),
    vim.log.levels.WARN
  )
end

local function validate_streaming_options()
  local streaming = M.options.streaming
  if type(streaming) ~= 'table' then
    warn_invalid('streaming', streaming, vim.inspect(defaults.streaming), 'a table')
    M.options.streaming = vim.deepcopy(defaults.streaming)
    return
  end

  local render_ms = streaming.render_interval_ms
  if not finite_number(render_ms) or render_ms < 10 or render_ms > 1000 then
    warn_invalid(
      'streaming.render_interval_ms',
      render_ms,
      defaults.streaming.render_interval_ms,
      'a finite number from 10 to 1000'
    )
    streaming.render_interval_ms = defaults.streaming.render_interval_ms
  else
    streaming.render_interval_ms = math.floor(render_ms + 0.5)
  end

  local markdown_hz = streaming.markdown_hz
  local valid_markdown_hz = finite_number(markdown_hz)
    and (markdown_hz < 0 or (markdown_hz >= 0.5 and markdown_hz <= 60))
  if not valid_markdown_hz then
    warn_invalid(
      'streaming.markdown_hz',
      markdown_hz,
      defaults.streaming.markdown_hz,
      'a negative number, or a finite number from 0.5 to 60'
    )
    streaming.markdown_hz = defaults.streaming.markdown_hz
  end
end

local REMOVED_CLAUDE_KEYS = {
  'claude_cmd',
  'extra_args',
  'model',
  'permission_mode',
}

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  validate_streaming_options()
  -- These former top-level Claude settings are intentionally unsupported.
  -- Drop them even if an old setup table still supplies them so no caller
  -- can accidentally observe or revive the compatibility path.
  for _, key in ipairs(REMOVED_CLAUDE_KEYS) do
    M.options[key] = nil
  end
  -- Re-apply highlight defaults so config.highlights overrides from setup()
  -- take effect (plugin/cc.lua ran set_defaults before setup was called).
  pcall(require('cc.highlight').set_defaults)
end

return M
