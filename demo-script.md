# cc.nvim YouTube Short Demo Script

Target length: 59 seconds  
Voiceover length: approximately 110 words

## Script

| Time | Actions / edit | Voiceover | On-screen text |
|---|---|---|---|
| 0:00–0:04 | Cold-open on the huge `implement-codex-support` session, fully expanded. Scroll rapidly, then hit `zM` to collapse everything. | “Agent sessions get huge. Terminal chat UIs make them feel even bigger.” | `126 tool calls → one buffer` |
| 0:04–0:09 | Hard cut to the clean cc.nvim split: output above, prompt below. Briefly highlight both panes. | “cc.nvim puts both Claude Code and Codex into native Neovim buffers.” | `CLAUDE + CODEX` / `NATIVE NEOVIM` |
| 0:09–0:16 | In the prompt buffer, edit a multiline Markdown prompt using normal Vim motions—move a line, change a word, undo once. | “Your prompt is just Markdown, so every motion, mapping, and completion already works.” | `A real Markdown buffer` |
| 0:16–0:23 | Submit with `<CR>`. Show the spinner and streamed response. While it runs, begin typing the next thought in the prompt buffer. Speed-ramp any waiting. | “Press Enter, and the response streams without taking over your editor.” | `ASYNC + STREAMING` |
| 0:23–0:34 | Jump to `add-opus-5-support`. Collapse with `zM`, open one `Edit` fold with `zo`, reveal the statusline diff, then open the focused test command and result. | “Tool calls fold into a scannable tree. Open only what matters: the command, its output, or a real inline diff.” | `FOLD THE NOISE` |
| 0:34–0:41 | Tight crop on the statusline. Let the viewer see model, effort, tokens, cost, branch, and session title. | “The statusline tracks the model, effort, tokens, cost, and git context.” | `MODEL · EFFORT · TOKENS · COST` |
| 0:41–0:50 | Run `:CcHistory`, select `implement-codex-support`, jump-cut through resume, then show the collapsed session. | “Past sessions are resumable—even this real, 126-tool-call session that added Codex support.” | `RESUME ANY SESSION` |
| 0:50–0:55 | Type `:CcNew sol high`. Match-cut from the Claude statusline to the Codex model appearing. | “And switching providers is one command.” | `:CcNew sol high` |
| 0:55–0:59 | End card over the clean two-buffer layout or logo. | “No TUI. No lost scrollback. Just Neovim and your agent. That’s cc.nvim.” | `github.com/robcmills/cc.nvim` |

## Real sessions to use

### Primary story: `add-opus-5-support`

```vim
:CcResume 83bcc4fc-764a-4538-a426-561b1c783998
```

This is the best complete story. It contains:

- A crisp opening request: “Claude Opus 5 was just released. Add support for it in cc.nvim.”
- 27 authentic tool calls.
- Code search and file reads.
- Inline edits to `statusline.lua` and its tests.
- Focused and full test runs.
- A concise final result.

Only expand the safe `Edit` and test folds. Leave its API/model-discovery commands collapsed.

### Folding and history: `implement-codex-support`

```vim
:CcResume fd66b8ac-1d88-4f5e-a975-2b1e992f3176
```

This session has 466 records and 126 tool calls across Bash, Read, Edit, Write, and task tracking. It makes `zR` → `zM` visually striking and supports the claim that cc.nvim handles substantial real work.

### Optional autonomous-outcome ending: `create-github-release`

```vim
:CcResume 68f8170e-7b8f-4cf8-af38-879756dba25d
```

This session begins with “do a github release” and ends with a published v0.9.0 release. Use it if the final beat should emphasize autonomous outcomes rather than provider switching.

## Live prompt

```markdown
Summarize the Opus 5 change in three bullets,
then rerun only the focused statusline tests.
```

## Recording notes

- Record vertically at roughly 80–90 columns with a large font.
- Use jump cuts on keystrokes and speed-ramp agent latency.
- Keep captions short and large enough for a phone screen.
- Make sure paths, notifications, and expanded tool output contain no private information before recording.
