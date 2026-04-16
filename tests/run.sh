#!/usr/bin/env bash
# cc.nvim test runner — agent entrypoint
#
# Usage:
#   ./tests/run.sh                         # Run all specs (minimal config)
#   ./tests/run.sh output_rendering        # Filter by pattern
#   ./tests/run.sh --visual simple_text    # Render fixture, dump visual output
#   ./tests/run.sh --config=rob            # Run with Rob's config
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
CONFIG="minimal"
PATTERN=""
VISUAL=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config=*)
      CONFIG="${1#--config=}"
      shift
      ;;
    --visual)
      VISUAL="$2"
      shift 2
      ;;
    *)
      PATTERN="$1"
      shift
      ;;
  esac
done

# Choose init file
case "$CONFIG" in
  minimal)
    INIT_FILE="$SCRIPT_DIR/minimal_init.lua"
    ;;
  rob)
    INIT_FILE="$SCRIPT_DIR/rob_init.lua"
    ;;
  *)
    echo "Unknown config: $CONFIG (use minimal or rob)"
    exit 1
    ;;
esac

# --visual mode: render one fixture and print layer-C dump
# Supports both JSONL (resume path) and NDJSON (streaming path) fixtures.
if [[ -n "$VISUAL" ]]; then
  FIXTURE=""
  FIXTURE_TYPE=""
  # Check JSONL first, then NDJSON
  if [[ -f "$SCRIPT_DIR/fixtures/jsonl/$VISUAL.jsonl" ]]; then
    FIXTURE="$SCRIPT_DIR/fixtures/jsonl/$VISUAL.jsonl"
    FIXTURE_TYPE="jsonl"
  elif [[ -f "$SCRIPT_DIR/fixtures/ndjson/$VISUAL.ndjson" ]]; then
    FIXTURE="$SCRIPT_DIR/fixtures/ndjson/$VISUAL.ndjson"
    FIXTURE_TYPE="ndjson"
  else
    echo "Fixture not found: $VISUAL"
    echo "Available JSONL:"
    ls "$SCRIPT_DIR/fixtures/jsonl/"*.jsonl 2>/dev/null | xargs -n1 basename | sed 's/.jsonl//'
    echo "Available NDJSON:"
    ls "$SCRIPT_DIR/fixtures/ndjson/"*.ndjson 2>/dev/null | xargs -n1 basename | sed 's/.ndjson//'
    exit 1
  fi
  echo "=== Visual dump: $VISUAL (type=$FIXTURE_TYPE, config=$CONFIG) ==="

  # Write the Lua script to a temp file to avoid quoting issues
  TMPSCRIPT=$(mktemp /tmp/cc_visual_XXXXXX.lua)
  cat > "$TMPSCRIPT" << LUAEOF
local Output = require('cc.output')
local Session = require('cc.session')
local config = require('cc.config')
config.setup({})
local session = Session.new()
local output = Output.new(session, 'cc-test-output')
local bufnr = output:ensure_buffer()
vim.api.nvim_set_current_buf(bufnr)

local fixture_type = '$FIXTURE_TYPE'
if fixture_type == 'jsonl' then
  local history = require('cc.history')
  local records = history.read_transcript('$FIXTURE')
  for _, rec in ipairs(records) do
    output:render_historical_record(rec)
  end
elseif fixture_type == 'ndjson' then
  local Parser = require('cc.parser')
  local Router = require('cc.router')
  local router = Router.new({ session = session, output = output })
  local parser = Parser.new()
  local lines = vim.fn.readfile('$FIXTURE')
  for _, line in ipairs(lines) do
    local messages = parser:feed(line .. '\n')
    for _, msg in ipairs(messages) do
      router:dispatch(msg)
    end
  end
end
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local state = require('cc.output')._buf_state[bufnr]
local fl = state and state.fold_levels or {}
local caret_ns = vim.api.nvim_get_namespaces()['cc.carets']
local caret_marks = {}
if caret_ns then
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, caret_ns, 0, -1, { details = true })) do
    caret_marks[m[2]] = m[4]
  end
end
for i, line in ipairs(lines) do
  local hl = ''
  if #line > 0 then
    local col = line:find('%S')
    if col then
      local id = vim.fn.synID(i, col, true)
      hl = vim.fn.synIDattr(id, 'name')
    end
  end
  local mark_info = ''
  local mark = caret_marks[i - 1]
  if mark and mark.virt_text then
    local vts = {}
    for _, vt in ipairs(mark.virt_text) do
      table.insert(vts, string.format("('%s','%s')", vt[1], vt[2] or ''))
    end
    mark_info = '  extmark=[' .. table.concat(vts, ',') .. ']'
  end
  io.write(string.format('%3d [fl=%-4s hl=%-12s] %s%s\n',
    i, tostring(fl[i] or ''), hl, line, mark_info))
end
vim.cmd('qa!')
LUAEOF

  CLEAN_FLAG=""
  if [[ "$CONFIG" == "minimal" ]]; then
    CLEAN_FLAG="--clean"
  fi
  nvim --headless $CLEAN_FLAG -u "$INIT_FILE" -S "$TMPSCRIPT" 2>/dev/null
  rm -f "$TMPSCRIPT"
  exit 0
fi

# Run tests via mini.test
cd "$REPO_ROOT"
echo "=== cc.nvim tests (config=$CONFIG) ==="

# Build file filter
if [[ -n "$PATTERN" ]]; then
  FILE_PATTERN="$PATTERN"
else
  FILE_PATTERN=""
fi

CLEAN_FLAG=""
if [[ "$CONFIG" == "minimal" ]]; then
  CLEAN_FLAG="--clean"
fi

nvim --headless $CLEAN_FLAG -u "$INIT_FILE" +"lua (function()
  local test = require('mini.test')
  local pattern = '$FILE_PATTERN'
  local collect_opts = {
    find_files = function()
      local files = vim.fn.glob('tests/cases/*_spec.lua', false, true)
      if pattern ~= '' then
        files = vim.tbl_filter(function(f) return f:find(pattern, 1, true) end, files)
      end
      return files
    end,
  }
  local execute_opts = {
    reporter = test.gen_reporter.stdout({ group_depth = 2 }),
  }
  test.run({ collect = collect_opts, execute = execute_opts })
end)()" +qa
