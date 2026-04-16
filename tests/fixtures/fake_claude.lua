#!/usr/bin/env -S nvim -l
-- Fake claude subprocess: replays an NDJSON fixture file to stdout.
-- Spawned by process.lua in place of the real `claude` CLI for testing.
--
-- Usage:
--   nvim -l tests/fixtures/fake_claude.lua --fixture=path/to/file.ndjson [ignored args...]
--
-- Behavior:
--   - Reads all lines from the fixture file
--   - Writes each line + newline to stdout (io.write)
--   - Waits briefly between lines to simulate streaming cadence
--   - Reads stdin (so process.lua's write path is exercised) but ignores it
--   - Exits cleanly after all lines are written
--   - Honors SIGINT (default behavior)

local fixture_path = nil

-- Parse args: find --fixture=<path>, ignore everything else
-- (process.lua passes -p, --input-format, --output-format, etc.)
for _, arg in ipairs(vim.v.argv) do
  local match = arg:match('^%-%-fixture=(.+)$')
  if match then
    fixture_path = match
  end
end

-- Also check for env var as alternative
if not fixture_path then
  fixture_path = vim.env.CC_TEST_FIXTURE
end

if not fixture_path then
  io.stderr:write('fake_claude: no --fixture=<path> arg or CC_TEST_FIXTURE env var\n')
  vim.cmd('cquit 1')
  return
end

-- Read fixture file
local lines = vim.fn.readfile(fixture_path)
if not lines or #lines == 0 then
  io.stderr:write('fake_claude: empty or unreadable fixture: ' .. fixture_path .. '\n')
  vim.cmd('cquit 1')
  return
end

-- Write each line to stdout with a small delay between them
for i, line in ipairs(lines) do
  io.stdout:write(line .. '\n')
  io.stdout:flush()
  -- Small delay to simulate streaming (5ms between lines)
  if i < #lines then
    vim.uv.sleep(5)
  end
end

-- Exit cleanly
vim.cmd('qall!')
