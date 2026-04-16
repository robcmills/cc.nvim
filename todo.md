
- [x] Collapse sequences of consecutive agent turns into a single fold
- [x] Figure out how to close the agentic loop for visual appearance (how to enable agent to "see" colored output)
- [x] Add tests (mini.test framework, 39 tests, 17 JSONL fixtures from real sessions)
  + [x] with no config (minimal_init.lua — vanilla neovim)
  + [ ] with my config (rob_init.lua — vertical buffers list, plugins, etc.)
  + [ ] streaming NDJSON fixtures (for hook events, tool_progress, cost display)
  + [ ] CI (GitHub Actions)
- [ ] Identify most complex/fragile code and simplify (requires brainstorming)
- [ ] Fix broken highlight groups
- [ ] Enable window config 
  - [ ] hide line numbers by default
  - [ ] wrap output by default
- [ ] Add support for session naming
- [ ] Add config option to show/hide thinking
- [ ] Tighten up poor vertical spacing and multiple consecutive blank lines
- [ ] Fix poor horizontal spacing and indentation (gaps after carets) (2 spaces not 4)
- [ ] Add unique "icons" for each entry and tool type (with nerdfont support) (configurable)
- [ ] Add configurable themes support for customizing highlight groups, icons, etc.
- [ ] Make resume history picker window larger
- [ ] Add support for todo lists (requires brainstorming)
- [x] Audit all claude code functionality for parity/selection of subset we will support (see tests/FEATURE_AUDIT.md)
- [ ] Autoscroll that can be toggled on/off (fix vertical scroll/snapping issues)
- [ ] Autosize prompt window to fit content (with configurable min/max heights)
- [ ] Add support for /remote-control
- [ ] Add statusline (requires brainstorming)
  - [ ] Show thinking spinner
  - [ ] Show token count (like claude code)
  - [ ] Show cost
  - [ ] Show mode
  - [ ] Show PR
  - [ ] Show session name
