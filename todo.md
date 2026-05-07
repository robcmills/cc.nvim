- [x] Fix foldlevel not persisting across navigations
- [ ] Add configurable markdown highlighting for Subagent prompts
- [ ] Fix missing mode in statusline on startup
- [ ] Add session timing info
- [ ] Investigate swapfile issue when two instances are editing the same file
- [ ] Add rename with ai generated name
- [ ] Remove parens around tool timers (add around timeouts)
- [ ] Explore potentially using foldcolumn
- [ ] Unsloppify - identify most complex/fragile code and simplify (requires brainstorming)
- [ ] Add config option to turn off tool icons
- [ ] Ensure system prompt additions are not hard-coded (instead user config)
- [ ] Add configurable themes support for customizing highlight groups, icons, etc.
- [ ] Add a "theme viewer/switcher" to show visually mock examples of what each type of tool looks like, and user can interactively switch themes and see what it looks like live
- [ ] Implement better resume and history search (:CcSessionSearch)
- [ ] Make resume history picker window larger
- [ ] Test/fix command completions (/rename, etc.)
- [ ] Audit all claude code functionality for parity/selection of subset we will support (see tests/FEATURE_AUDIT.md)
- [ ] Support "queued" prompts (submitted while agent is thinking or working)
- [ ] Add support for /remote-control
- [ ] Add support plan mode toggle
- [ ] Add support for /compact (requires brainstorming)

- [ ] Expose visibility into long running bash tool calls? (a way to see output while it's running)
```
   Bash: Run GlobalConfigControllerTest 󰔛 timeout 300s (170s)
    cd /Users/robcmills/src/openspace/backend && ./gradlew :platform:test --tests "openspace.platform.controller.api.v3.GlobalConfigControllerTest" 2>&1 | tail -40
```

- [x] Refactor architecture to use output buffer as parent instead of prompt buffer
- [x] add prompt placeholder 
- [x] Add config option to autosize prompt window to fit content (with configurable min/max heights)
- [x] Enable window config 
  - [x] hide line numbers by default
  - [x] wrap output by default
- [x] Add syntax highlighting for code blocks in output
  + [x] mcp__claude-in-chrome__javascript_tool.text (contains javascript)
- [x] Turn thinking back on with timer
- [x] Collapse sequences of consecutive agent turns into a single fold
- [x] Figure out how to close the agentic loop for visual appearance (how to enable agent to "see" colored output)
- [x] Add tests (mini.test framework, 111 tests, 17 JSONL + 11 NDJSON fixtures)
  + [x] with no config (minimal_init.lua — vanilla neovim)
  + [x] with my config (rob_init.lua — vertical buffers list, plugins, etc.)
  + [x] streaming NDJSON fixtures (hook events, tool_progress, cost display, subagent tasks, thinking, plan mode)
  + [x] process-level integration tests (fake_claude.sh → full pipeline)
  + [x] caret extmark sync tests (▾/▸ on fold headers)
  + [x] history resume tests (read_transcript, render_historical_record, truncation)
  + [x] --capture flag for run.sh (interactive NDJSON fixture capture)
  + [ ] CI (GitHub Actions)
- [x] Autoscroll (fix vertical scroll/snapping issues)
- [x] Fix folding issues
  output is too expanded by default, shows tool output, 
  - [x] when output is focused, it collapses. Folding should not change due to output being focused.
- [x] Prompt submission should turn output tailing back on
- [x] Add configurable statusline (requires brainstorming for UI)
- [x] Add config option to show/hide thinking
- [x] Tighten up poor vertical spacing and multiple consecutive blank lines
- [x] Fix poor horizontal spacing and indentation (gaps after carets) (2 spaces not 4)
- [x] Add unique "icons" for each entry and tool type (with nerdfont support) (configurable)
- [x] Rename "Agent" tool to "Subagent"
- [x] Format bash tool calls to show description first then command
- [x] Format git commit tool calls to show commit message
- [x] Format TodoWrite to look like a nice todo list
- [x] Interrupt current turn via stream-json control_request (keeps session alive)
- [x] Fix statusline thinking spinner (doesn't spin)
- [x] Remove turn spinners
- [x] Add support for session naming (/rename)
- [x] Prevent user prompt submission while agent turn is active
- [x] Get rid of full line background highlight for folded lines (especially distracting on Output lines)
- [x] Rename CcNew -> CcClear and CcOpen -> CcNew
- [x] Add effort level to statusline
- [x] `zt` bug is resurfacing
- [x] Add true e2e tests (requires brainstorming)
- [x] Fix :BuffersNext/Prev not working in output window
- [x] Add per tool call statusline (Running... (32s timeout 2m)) -> resolves to (42s)
- [x] Add emoji art splash screen (configurable visibility)
- [x] Improve hightlights for todo lists
  + [x] completed task icons are green
  + [x] in progress task icons are yellow
  + [x] incomplete task icons are gray

