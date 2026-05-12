# `:CcPeek` MVP Plan

Peek into running Bash tool calls from inside cc.nvim by tailing a per-tool log
file in a floating window. Uses a Claude Code `PreToolUse` hook to deterministically
wrap long-running Bash commands in `tee` so the log file always exists.

## Goals (v0)

- Show running Bash tool calls in the **current cc.nvim session**.
- Open a floating window that **live-tails** the chosen call's output.
- Opt-in via `:CcPeekInstall` / `:CcPeekUninstall` (writes the hook).
- Validate the install via `:checkhealth cc`.
- Reliable cleanup, including across crashes.

## Non-goals (v0)

- Global picker across sessions/projects (`:CcPeek all`).
- Re-reading completed runs (`:CcPeek!`).
- Hiding the `tee` wrap from the conversation buffer's tool header (visual polish).
- `script(1)` fallback for full-buffered tools (only if `tee` proves insufficient).

---

## 1. Hook script — `~/.claude/hooks/cc-peek-wrap.sh`

Shipped from `cc.nvim/hooks/cc-peek-wrap.sh`, copied into place by `:CcPeekInstall`.

**Inputs** (stdin JSON, confirmed against `claude-code/src/utils/hooks.ts:3418`):
`session_id`, `tool_name`, `tool_use_id`, `tool_input.command`, `tool_input.timeout`.

**Logic**:
1. `umask 077` at the top of the script so any file/dir created is mode 0600/0700.
2. Validate `session_id` and `tool_use_id` match `^[A-Za-z0-9_-]+$`; if not,
   echo input unchanged and exit 0 (defense in depth against shell injection,
   even though both are UUIDs in practice).
3. If `tool_name != "Bash"` or `timeout < 30000` (or missing) → echo input unchanged, exit 0.
4. Else compute `LOG="${XDG_CACHE_HOME:-$HOME/.cache}/cc-peek/$session_id/$tool_use_id.log"`,
   `mkdir -p "$(dirname "$LOG")"`.
5. Wrap with `set -o pipefail` so exit code propagates:
   ```bash
   set -o pipefail; { <orig>; } 2>&1 | tee "$LOG"
   ```
6. Emit JSON (schema from `claude-code/src/types/hooks.ts:72`):
   ```json
   { "hookSpecificOutput": { "hookEventName": "PreToolUse",
       "permissionDecision": "allow",
       "updatedInput": { "command": "<wrapped>", "timeout": <orig> } } }
   ```

### Performance notes

- Hook overhead per Bash call: ~10–30ms (fork bash + JSON I/O). Negligible.
- `tee` cost: microseconds per write; immaterial for normal Bash workloads.
- **Output buffering is the real catch.** When stdout is a pipe to `tee` rather
  than a TTY, libc switches most programs from line-buffered to block-buffered.
  Progress bars may disable themselves; output arrives in chunky bursts. Wall-
  clock unchanged, but the "live" peek feels laggy on slow commands. Start
  with `tee` anyway; swap to `script -fq "$LOG" -c "$orig"` (allocates a pty,
  preserves line buffering) if it proves bad in practice. Isolated change.

### Security

- **Per-user cache dir** (`~/.cache/cc-peek/`), not `/tmp`. Eliminates the
  shared-dir readability problem and symlink/TOCTOU risk in `/tmp`.
- **`umask 077`** in the hook → all files mode 0600, dirs mode 0700.
- **Regex validation** of `session_id` / `tool_use_id` before substitution into
  shell — defense in depth.
- **Disclosure**: README must note that Bash output (potentially containing
  secrets the command prints) lands on disk under `~/.cache/cc-peek/` until
  cleanup. Users who don't want the residue should run `:CcPeekUninstall`.

## 2. Plugin module — `lua/cc/peek.lua` (new, ~150 LOC)

At module load, resolve once:
```lua
M._cache_root = (vim.env.XDG_CACHE_HOME or (vim.env.HOME .. '/.cache')) .. '/cc-peek'
```

Public API:

```lua
M.list_running(bufnr)   -- → array of { id, command, started, log_path }
M.open(bufnr, id)       -- open float, start tail, register cleanup
M.gc()                  -- prune stale <cache_root>/*/ dirs
M.teardown(bufnr)       -- called from cc.init's per-bufnr cleanup
M.install()             -- :CcPeekInstall
M.uninstall()           -- :CcPeekUninstall
```

`list_running` is pure derivation from `session.tool_calls`. The log-path
pattern is built from `M._cache_root` (escaped via `vim.pesc`) plus
`/[%w%-]+/[%w%-]+%.log`:

```lua
local pat = vim.pesc(M._cache_root) .. '/[%w%-]+/[%w%-]+%.log'
for id, rec in pairs(sess.tool_calls) do
  if rec.name == 'Bash' and not rec.result then
    local log = rec.input.command:match(pat)
    if log then
      table.insert(out, {
        id = id,
        command = strip_wrap(rec.input.command),
        started = rec.start_time,
        log_path = log,
      })
    end
  end
end
```

`strip_wrap` collapses `set -o pipefail; { X; } 2>&1 | tee "<cache>/.../.log"`
back to `X` for display.

## 3. `:CcPeek` command (registered in `plugin/cc.lua`)

```
:CcPeek
```

- 0 candidates → `vim.notify('cc-peek: no peekable Bash running', INFO)`.
- 1 candidate → `peek.open(bufnr, id)` directly.
- 2+ candidates → `vim.ui.select(candidates, { format_item = ... })` then `peek.open`.

Format item: `<elapsed>s  <command-truncated>`.

Calls `peek.gc()` once at the top of the handler.

## 4. Float + live tail

Pattern: copy `interactive.open_plan_float` (`lua/cc/interactive.lua:55`) for the
window; spawn `tail -f` via `vim.uv.spawn` (same primitive as `process.lua`).

- Buffer: `nofile`, `nomodifiable`, `ft=log`, `BufHidden=wipe`.
- Window: square border, 80% × 70%, centered. Keymaps `q` and `<Esc>` close it.
- On stdout chunk → `vim.schedule(append_lines)`. Auto-scroll to bottom unless
  cursor is not on last line (user is reading).
- Per-window state: `{ tail_handle, tool_use_id, bufnr }`. Cleanup in two cases:
  1. **Window closed** (`BufWipeout` autocmd) → kill `tail_handle`.
  2. **Tool completes** (hook into `router.lua` where `tool_result` lands) →
     kill `tail_handle`, prepend virt_text `[done in Ns, exit C]`. Don't auto-close.

## 5. Cleanup

Two layers:

**Active** — in the prompt-buffer teardown path (existing `_buf_state` wipe in
`lua/cc/init.lua`):
```lua
vim.fn.delete(M._cache_root .. '/' .. session_id, 'rf')
```

**Lazy GC** — `peek.gc()` runs once per `:CcPeek` invocation:
- Walk `<cache_root>/*/`.
- Delete any dir whose name ≠ current `session_id` AND whose mtime is older
  than `gc_max_age_seconds` (default 3600). Configurable so users who care
  about residue can shorten it.
- Bounded cost, no daemon.

Trade-off vs. the earlier `/tmp` proposal: we lose the OS-level fallback
(`/tmp` cleanup by `periodic` / systemd-tmpfiles), but gain per-user privacy
and predictable paths. Net win — the active + lazy layers already cover
the common cases.

## 6. `:CcPeekInstall` / `:CcPeekUninstall`

`:CcPeekInstall`:
1. Copy `cc.nvim/hooks/cc-peek-wrap.sh` → `~/.claude/hooks/cc-peek-wrap.sh`, chmod +x.
2. Read `~/.claude/settings.json` (create with `{}` if missing).
3. Idempotently insert under `hooks.PreToolUse` a matcher entry for `Bash` calling
   the script. Skip if already present (match by command path).
4. **Atomic write**: serialize via `vim.json.encode`, write to
   `settings.json.cc-peek.tmp` in the same directory, then `vim.uv.fs_rename`
   into place. Prevents corruption if another claude session is writing
   `settings.json` concurrently.
5. `vim.notify('cc-peek: installed. Restart any running claude sessions to pick up the hook.')`.

`:CcPeekUninstall`: reverse — remove the matcher entry, write back atomically,
leave the rest of `settings.json` alone. Leave the script in place (harmless).

## 7. `:checkhealth cc` additions in `lua/cc/health.lua`

New section after the existing checks:

```lua
h.start('cc-peek')
```

Checks:
1. **Hook script exists & executable** at `~/.claude/hooks/cc-peek-wrap.sh` →
   `h.ok` / `h.warn('run :CcPeekInstall')`.
2. **Settings.json registers it** under `PreToolUse` matcher=`Bash` → `h.ok` / `h.warn`.
3. **Smoke test**: invoke the script with a synthetic stdin payload (long-timeout
   Bash), assert output JSON contains a `tee "<cache_root>/...` substring →
   `h.ok` / `h.error` with reason.
4. **Current-session log dir** at `<cache_root>/<session_id>/` → list count of
   files (info, not error).

## 8. Tests (mini.test)

- `tests/cases/peek_spec.lua` — unit:
  - `list_running` correctly filters by Bash + missing `result` + matchable path.
  - `strip_wrap` collapses the wrap back to the original command.
  - GC respects mtime threshold and excludes current session.
  - Hook script (run as a real subprocess from the test) wraps long timeouts,
    leaves short ones alone, leaves non-Bash alone.
- `tests/cases/peek_install_spec.lua`:
  - `install`/`uninstall` against a temp `XDG_CONFIG_HOME` produce idempotent
    settings.json edits.

No e2e test for the float + tail in v0; defer until the basic mechanics are stable.

## 9. Files touched / added

```
plugin/cc.lua                       +3 lines  (register :CcPeek*)
lua/cc/peek.lua                     new       (~150 LOC)
lua/cc/health.lua                   +30 lines (cc-peek section)
lua/cc/router.lua                   +5 lines  (notify peek module on tool_result)
lua/cc/init.lua                     +2 lines  (call peek teardown in _buf_state wipe)
hooks/cc-peek-wrap.sh               new       (~40 LOC, shipped in repo)
tests/cases/peek_spec.lua           new
tests/cases/peek_install_spec.lua   new
README.md                           +1 short section
```

## 10. Verified facts

- PreToolUse hook input includes `tool_use_id`, `session_id`, `tool_name`,
  `tool_input` (`claude-code/src/utils/hooks.ts:3394–3424`).
- Hook can rewrite the command via `hookSpecificOutput.updatedInput`
  (`claude-code/src/types/hooks.ts:72–78`).
- `lua/cc/health.lua` already exists with the right `h.start/h.ok/h.warn` pattern.
- `session.tool_calls[id]` already records `{ name, input, result, start_time }`
  (`lua/cc/session.lua:46`); "running" = entry without `result`.
- `tool_use_id` is the deterministic key both ends already agree on.
- `interactive.open_plan_float` (`lua/cc/interactive.lua:55`) is the existing
  floating-window pattern to reuse.
