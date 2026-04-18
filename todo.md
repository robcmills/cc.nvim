
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
- [ ] Fix folding issues
  output is too expanded by default, shows tool output, 
  - [ ] when output is focused, it collapses. Folding should not change due to output being focused.
- [ ] Add per tool call statusline (Running... (32s timeout 2m))
- [ ] support plan mode toggle
- [ ] Autosize prompt window to fit content (with configurable min/max heights)
- [ ] Identify most complex/fragile code and simplify (requires brainstorming)
- [ ] Fix broken highlight groups
- [ ] Support "queued" prompts (submitted while agent is thinking or working)
- [ ] Enable window config 
  - [ ] hide line numbers by default
  - [ ] wrap output by default
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
- [ ] Add configurable statusline (requires brainstorming for UI)
  - [ ] Show thinking spinner
  - [ ] Show token count (like claude code)
  - [ ] Show cost
  - [ ] Show mode (plan, auto, etc.)
  - [ ] Show PR
  - [ ] Show effort level
  - [ ] Show model
  - [ ] Show claude code version
  - [ ] Show session name
  - [ ] Show remote control status (if active)


- [ ] mimic cc tools format:
```
⏺ Search(pattern: "getLaunchDarklyFlags|MOCK_LAUNCH_DARKLY_FLAGS", path: "/Users/robcmills/src/openspace/web/icedemon/e2e")
  ⎿  Found 10 files

⏺ Read(/Users/robcmills/src/openspace/web/icedemon/e2e/cypress/support/commands/interceptFlags.ts)
  ⎿  Read 45 lines
```
