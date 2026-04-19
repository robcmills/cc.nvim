# Output Window Statusline

User-configurable statusline rendered at the bottom of the output window. The
user supplies a function that receives a state table and returns a Neovim
statusline string.

## Goals

- Let users compose their own statusline from the agent's live state.
- Zero cost when disabled. Opt-in via config.
- Redraw only on state transitions, not every frame.
- Output window only (for now) — prompt window unchanged.

## Public API

### Config shape (`lua/cc/config.lua`)

```lua
statusline = {
  enabled = true,
  -- function(state) -> string. If nil, a default format is used.
  format = nil,
},
```

Statusline is on by default. Users disable with `enabled = false` or replace
the rendering by supplying `format`.

Deep-merged by `vim.tbl_deep_extend` (already the pattern).

### State table passed to `format(state)`

```lua
{
  is_thinking     = boolean,  -- assistant currently streaming / tool running
  total_tokens    = number,   -- input + output (cumulative for session)
  input_tokens    = number,
  output_tokens   = number,
  cost_usd        = number,
  mode            = string,   -- "plan" | "auto" | "default" | "bypassPermissions" | ...
  branch          = string?,  -- git branch of cwd, nil if not a repo
  pr              = string?,  -- e.g. "#1234", nil if none / gh unavailable
  effort          = string?,  -- reasoning effort if surfaced by CLI
  model           = string?,  -- e.g. "claude-opus-4-7"
  cli_version     = string?,  -- claude CLI version, e.g. "2.1.3"
  session_name    = string?,  -- nil until naming feature lands
  session_id      = string?,
  remote_control  = boolean,  -- true if a control request is pending / active
}
```

Unknown / unsupported fields are `nil` — user formats guard with `or ""`.

### Default format (used when `format == nil`)

```
{thinking} {tokens} {mode} {branch}{pr?} {session_name} {remote_control}
```

Segment rules:

- `{thinking}` — a spinner glyph while `is_thinking`, empty string otherwise.
- `{tokens}` — `total_tokens` formatted (e.g. `1.2k`); empty until the first
  `result` event populates it.
- `{mode}` — `permission_mode` as-is (`plan`, `auto`, `default`, ...).
- `{branch}{pr?}` — branch name; appended with ` #1234` when a PR is cached.
  Empty when not in a git repo.
- `{session_name}` — only rendered when set (reserved field; empty until the
  session-naming feature lands).
- `{remote_control}` — a short indicator (e.g. `⚡`) only while
  `remote_control` is true.

Segments separated by a single space; empty segments collapse so the
statusline doesn't show stray separators. Rendered with `%#HlGroup#` groups
mapped to existing cc.nvim highlights. Power users override via `format`.

## Architecture

### New module: `lua/cc/statusline.lua`

Responsibilities:

- `M.build_state(instance) -> table` — snapshot current state from
  `instance.session`, `instance.process`, config, and cached git/cli info.
- `M.render(instance) -> string` — call user `format(state)` (or default) and
  return the statusline string. Wrapped in `pcall`; on error logs once and
  falls back to a minimal format so a broken user function doesn't break the
  window.
- `M.attach(instance)` — set `vim.wo[winid].statusline = '%!v:lua.require("cc.statusline").render_for(' .. winid .. ')'`
  on the output window. Also sets `laststatus=2` buffer-locally is not a
  thing; we rely on global `laststatus` (document this, don't fight it).
- `M.refresh(instance)` — triggers `vim.cmd('redrawstatus')` scoped to the
  output winid. Cheap; called from event hooks.
- Internal `_winid_to_instance` map so `render_for(winid)` can look up the
  owning instance without a closure (required because `%!` evaluates a
  vimscript expression that can only call a global lua function).

### Module: `lua/cc/git.lua` (new)

Thin, cached git info for the plugin's cwd.

- `M.branch()` — `git -C <cwd> rev-parse --abbrev-ref HEAD` via `vim.system`
  (async). Result cached; invalidated by a `DirChanged`, `FocusGained`
  autocmd, or manual `M.invalidate()`.
- `M.pr()` — `gh pr view --json number -q .number` via `vim.system`. Same
  cache. Skipped silently if `gh` isn't on PATH.
- Both run once per cache window (e.g. 30s) and never block the render path.
  `build_state` reads only the cached value; if nothing is cached yet the
  field is `nil` and a background fetch is kicked off.

### CLI version

Already probed by `lua/cc/health.lua` via `claude --version`. Extract into
`lua/cc/version.lua` (or a helper in an existing module) so statusline and
health share a single cached value. Populated once on first `open()`.

### Effort level

Not currently tracked. Two options:

1. Omit for now — field stays `nil`.
2. Parse from `extra_args` / CLI flags in config at setup time.

Recommended: (2) if trivial, else (1) with a TODO.

### Remote control status

Set/cleared by `lua/cc/interactive.lua` around a control request lifecycle.
Add a boolean on the instance (e.g. `instance.remote_control_active`) toggled
at the existing request start / resolve / cancel points. Statusline reads it.

### Session name

Reserved field. Wires in once the "Add support for session naming"
todo lands. Until then, statusline passes `nil`.

## Wiring / Redraw Points

Call `statusline.refresh(instance)` from:

- `router.lua` on `message_start` / `message_stop` / `result` (covers
  `is_thinking`, token totals, cost).
- `session.lua` setters for `model`, `permission_mode` (mode changes after
  init system message and after `/plan`, `/auto` slash commands).
- `init.lua` `M.plan()` / any mode transition helper.
- `interactive.lua` on control request start / end (remote control flag).
- `process.lua` on process start / exit (clears thinking on unexpected exit).

Each of these is a single cheap call; no throttling needed initially.

## Attaching to the Window

In `Output:_setup_window_opts_for_buffer()` (`lua/cc/output.lua:93`):

```lua
if config.statusline and config.statusline.enabled then
  require('cc.statusline').attach(self.instance, winid)
end
```

Reset on `BufWinLeave` is not required — window-local options vanish with the
window. We do need to clear `_winid_to_instance[winid]` on `WinClosed`.

## Edge Cases

- Output window not yet open: `attach` is idempotent / no-op.
- User supplies a `format` that errors: `pcall`, log once per instance, fall
  back to default.
- User supplies a `format` that returns non-string: coerce with `tostring`,
  or fall back.
- Git calls fail (not a repo, no network for `gh`): cache `nil`, don't retry
  until cache window expires.
- Laststatus global: if user has `laststatus=0` or `1`, our window won't show
  one. Document in README; do not override the global.

## Testing (mini.test)

New test file: `tests/test_statusline.lua`.

- `build_state` returns expected fields given a fake instance.
- `render` calls user `format` and returns its string.
- `render` falls back to default when `format` errors.
- `render` falls back to default when `format` returns a non-string.
- `refresh` is a no-op when `enabled = false`.
- Mode change triggers a refresh (spy on `redrawstatus`).
- Git module returns cached value and does not re-spawn inside the cache
  window (mock `vim.system`).

## Rollout Steps

1. Add `statusline` block to `lua/cc/config.lua` defaults.
2. Add `lua/cc/statusline.lua` with `build_state`, `render`, `render_for`,
   `attach`, `refresh`.
3. Add `lua/cc/git.lua` with cached `branch` / `pr`.
4. Extract CLI version probe into a shared cached helper.
5. Wire `attach` into `Output:_setup_window_opts_for_buffer()` behind the
   config flag.
6. Wire `refresh` calls at the redraw points listed above.
7. Add `remote_control_active` flag in `interactive.lua`.
8. Tests.
9. README section: config example + state-table reference + default format
   snippet.
10. Add entry to `todo.md` and mark done.

## Out of Scope (follow-ups)

- Prompt window statusline (easy to add later; same module).
- Winbar variant.
- Per-tool-call "Running… (32s)" status — separate todo already exists.
- Session naming — waiting on its own feature.
