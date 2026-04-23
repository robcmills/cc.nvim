local M = {}

---@class cc.Config
local defaults = {
  -- Claude CLI
  claude_cmd = 'claude',
  permission_mode = nil, -- nil | 'auto' | 'acceptEdits' | 'plan' | 'bypassPermissions'
  model = nil, -- nil | 'sonnet' | 'opus' | model string
  extra_args = {}, -- additional CLI args

  -- Layout
  layout = 'horizontal', -- 'horizontal' | 'vertical'
  prompt_height = 10, -- lines for prompt buffer (horizontal layout)

  -- Folding
  default_fold_level = 2, -- 0=minimal, 1=summaries, 2=inputs, 3=all
  max_tool_result_lines = 50,
  foldtext = nil, -- function(info)->string or nil for default; see output.default_foldtext

  -- Tool input body formatter.
  -- function(tool_name, input) -> string | nil
  -- Return a string (newlines allowed) to render below the tool header.
  -- Return nil to defer to the default formatter. Indentation is added by the renderer.
  tool_input_format = nil,

  -- History / resume
  history_max_records = 500, -- cap records rendered on resume; older collapsed into a notice

  -- Display
  show_thinking = false,
  -- Per-turn cost/usage line appended to the output buffer after each turn.
  -- (Distinct from the session-cumulative tokens shown in the statusline.)
  show_turn_cost = true,
  -- Formatter for that line. function(result) -> string | nil
  -- `result` is the raw CLI result message; relevant fields are
  -- result.total_cost_usd and result.usage.{input_tokens, output_tokens,
  -- cache_creation_input_tokens, cache_read_input_tokens}. Return a string
  -- (the inner text — the `  ── ... ──` wrapping is added by the renderer)
  -- or nil to fall back to the default format.
  turn_cost_format = nil,
  tool_icons = {
    use_nerdfont = nil, -- nil = auto-detect (nvim-web-devicons / mini.icons); true/false to force
    default = nil, -- icon for unknown tools; nil uses built-in fallback
    icons = {}, -- per-tool override map, e.g. { Read = '📖', Bash = '$' }
  },
  line_numbers = {
    output = false, -- show line numbers in the output window
    prompt = false, -- show line numbers in the prompt window
  },
  wrap = {
    output = true, -- soft-wrap lines in the output window
    prompt = true, -- soft-wrap lines in the prompt window
  },

  -- Highlight overrides for cc-owned groups. When left nil, built-in
  -- defaults apply (and colorschemes defining the same group still win).
  -- When set, the spec is applied unconditionally — use this to force
  -- a look regardless of the active colorscheme.
  highlights = {
    -- Folded line in the output window. Builtin default is { bg = 'NONE' }
    -- so the fold inherits the normal background (keeps folds visually
    -- quiet). Accepts any nvim_set_hl spec: { fg, bg, italic, link, ... }.
    fold = nil,
  },

  -- Statusline on the output window.
  -- format = function(state) -> string (Neovim statusline syntax).
  -- state fields: is_thinking, spinner_frame, total_tokens, input_tokens,
  --   output_tokens, cost_usd, mode, branch, pr, effort, model, cli_version,
  --   session_name, session_id, remote_control.
  -- is_thinking is true from user submit through the final result message,
  -- i.e. the whole span in which the agent is busy (including tool calls
  -- and permission prompts).
  -- spinner.use_nerdfont: nil (auto-detect), true, or false. nil defers to
  -- nvim-web-devicons / mini.icons being loadable.
  statusline = {
    enabled = true,
    format = nil,
    spinner = {
      -- nil = auto-detect (mirrors tool_icons.use_nerdfont); true/false forces.
      use_nerdfont = nil,
      -- Active frames. nil => resolve from frames_nerdfont / frames_unicode
      -- based on use_nerdfont. Users may set any of these three.
      frames = nil,
      -- Nerd Font fa-hourglass cycle (U+F254, U+F251, U+F252, U+F253).
      frames_nerdfont = {
        '\xef\x89\x94',
        '\xef\x89\x91',
        '\xef\x89\x92',
        '\xef\x89\x93',
      },
      -- Plain Unicode braille cycle — renders in any terminal.
      frames_unicode = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
      interval_ms = 500,
    },
  },

  -- Keymaps
  keymaps = {
    submit = '<CR>', -- prompt buffer, normal mode
    interrupt = '<C-c>',
    clear_prompt = '<C-l>',
    goto_prompt = 'gp', -- output buffer
    goto_output = 'go', -- prompt buffer
  },
}

M.options = vim.deepcopy(defaults)

---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  -- Re-apply highlight defaults so config.highlights overrides from setup()
  -- take effect (plugin/cc.lua ran set_defaults before setup was called).
  pcall(require('cc.highlight').set_defaults)
end

return M
