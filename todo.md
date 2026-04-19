
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
- [ ] Add per tool call statusline (Running... (32s timeout 2m))
- [ ] support plan mode toggle
- [ ] Autosize prompt window to fit content (with configurable min/max heights)
- [ ] Identify most complex/fragile code and simplify (requires brainstorming)
- [ ] Fix broken highlight groups
- [ ] Support "queued" prompts (submitted while agent is thinking or working)
- [ ] Enable window config 
  - [x] hide line numbers by default
  - [x] wrap output by default
- [ ] Add support for session naming
- [x] Add config option to show/hide thinking
- [x] Tighten up poor vertical spacing and multiple consecutive blank lines
- [x] Fix poor horizontal spacing and indentation (gaps after carets) (2 spaces not 4)
- [ ] Add unique "icons" for each entry and tool type (with nerdfont support) (configurable)
- [ ] Add configurable themes support for customizing highlight groups, icons, etc.
- [ ] Customize git commit tool calls to show commit message
- [ ] Make resume history picker window larger
- [ ] Add support for todo lists (requires brainstorming)
- [x] Audit all claude code functionality for parity/selection of subset we will support (see tests/FEATURE_AUDIT.md)
- [ ] Add support for /remote-control
- [ ] Rename "Agent" tool to "Subagent"
- [ ] Add lua types
- [ ] Add configurable statusline (requires brainstorming for UI)
  - [ ] Show thinking spinner
  - [ ] Show token count (like claude code)
  - [ ] Show cost
  - [ ] Show mode (plan, auto, etc.)
  - [ ] Show branch/PR
  - [ ] Show effort level
  - [ ] Show model
  - [ ] Show claude code version
  - [ ] Show session name
  - [ ] Show remote control status (if active)

- [ ] Format TodoWrite to look like a nice todo list
   TodoWrite: #8
    {"todos":[{"activeForm":"Adding statusline config defaults","status":"in_progress","content":"Add statusline config defaults"},{"activeForm":"Creating git helper module","status":"pending","content":"Create lua/cc/git.lua with cached branch/pr"},{"activeForm":"Creating version helper module","status":"pending","content":"Create lua/cc/version.lua for cached CLI version"},{"activeForm":"Creating statusline module","status":"pending","content":"Create lua/cc/statusline.lua with build_state/render/attach/refresh"},{"activeForm":"Wiring attach into output window","status":"pending","content":"Wire attach into output window setup"},{"activeForm":"Wiring refresh calls at events","status":"pending","content":"Wire refresh calls at router/session/process events"},{"activeForm":"Adding remote control flag","status":"pending","content":"Add remote_control_active flag in interactive.lua"},{"activeForm":"Adding statusline tests","status":"pending","content":"Add tests in tests/test_statusline.lua"}]}

