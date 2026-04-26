
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


- [ ] Turn thinking back on with timer
- [ ] Fix missing mode in statusline on startup
- [ ] Add support for /remote-control
- [ ] Add session timing info
- [ ] Add rename with ai generated name
- [ ] Add syntax highlighting for code blocks in output
  + [ ] mcp__claude-in-chrome__javascript_tool.text (contains javascript)
- [ ] Explore potentially using foldcolumn
- [ ] Identify most complex/fragile code and simplify (requires brainstorming)
- [ ] Add config option to turn off tool icons
- [ ] Ensure system prompt additions are not hard-coded (instead user config)
- [ ] Enable window config 
  - [x] hide line numbers by default
  - [x] wrap output by default
- [ ] Add configurable themes support for customizing highlight groups, icons, etc.
- [ ] Add a "theme viewer/switcher" to show visually mock examples of what each type of tool looks like, and user can interactively switch themes and see what it looks like live
- [ ] Make resume history picker window larger
- [ ] Audit all claude code functionality for parity/selection of subset we will support (see tests/FEATURE_AUDIT.md)
- [ ] Improve lua types
- [ ] Add config option to autosize prompt window to fit content (with configurable min/max heights)
- [ ] Add support plan mode toggle
- [ ] Add support for todo lists (requires brainstorming)
- [ ] Add support for /compact (requires brainstorming)
- [ ] Support "queued" prompts (submitted while agent is thinking or working)

