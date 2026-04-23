# Contributing to cc.nvim

Thanks for your interest in making this less sloppy. All contributions are
welcome, bug reports, patches, test fixtures, docs fixes, nitpicks about
variable names. This was built to scratch a personal itch, so fresh eyes
catch things I won't. It works on my machine, but I would love to stress test
it on yours.

## Ways to help

- **File an issue.** Bugs, crashes, weird rendering, UX papercuts,
  feature requests. Include your Neovim version (`nvim --version`), your
  `claude` CLI version (`claude --version`), OS, and — ideally — a
  reproduction (a minimal prompt, a fixture, or steps).
- **Capture a fixture.** If you hit a rendering glitch, run
  `./tests/run.sh --capture <name>`, reproduce the issue, and attach the
  resulting `tests/fixtures/ndjson/<name>.ndjson`. That alone makes bugs
  ~10x easier to fix.
- **Send a PR.** Small, focused diffs are easier to review. If you're
  planning something larger, open an issue first so we can align on
  direction before you sink time into it.
- **Improve docs.** The README is long and unavoidably drifts. If
  something is wrong, stale, or confusing, say so (or fix it).
- **Suggest a better highlight / icon / layout default.** Aesthetics
  matter. If a default is ugly or unreadable in your colorscheme, open
  an issue with a screenshot.

## Development setup

```bash
git clone https://github.com/<you>/cc.nvim
cd cc.nvim
git submodule update --init --recursive   # pulls in mini.nvim for tests
./tests/run.sh                            # make sure the baseline passes
```

Point your Neovim config at the local checkout (see
[Installation](README.md#installation) in the README). Changes take effect
on the next `:CcOpen` / Neovim restart.

## Running tests

```bash
./tests/run.sh                        # all specs
./tests/run.sh output_rendering       # pattern filter by spec filename
./tests/run.sh --visual simple_text   # render a fixture, print visual dump
./tests/run.sh --capture my_feature   # capture a new NDJSON fixture
```

New behavior should come with a test. The [Testing section of the
README](README.md#testing) covers the two fixture paths (JSONL resume vs.
NDJSON streaming) and how to write specs against them.

## Style

- Pure Lua, no Vimscript beyond `plugin/cc.lua` bootstrap.
- Match the existing style — no build step or formatter, just eyeball it.
- Keep public API changes backwards-compatible when you can. If you must
  break something, call it out in the PR description.
- Don't add new dependencies without a good reason. The point of this
  plugin is zero-deps-beyond-what-you-have.
- User-visible strings go through config where reasonable so users can
  override them.

## Commit + PR hygiene

- One logical change per commit is nice but not mandatory.
- PR descriptions should say *why*, not just *what* — the diff shows the
  what.
- If you added a fixture, mention what it covers and how you captured it.
- Screenshots or asciicasts for any visible UI change are appreciated.

## Scope

Things that are in scope: anything that improves the editor experience of
using the Claude Code CLI from Neovim. Things that are probably out of
scope: reimplementing features that belong in the `claude` CLI itself
(auth, model routing, MCP protocol internals). When in doubt, open an
issue and ask.

On my todo list is to extensively audit claude code functionality and 
determine what subset of that cc.nvim will support. In my opinion, claude
code is getting bloated.

## Code of conduct

Be kind. Assume good faith. If someone's PR is rough, help them improve
it instead of closing it.
