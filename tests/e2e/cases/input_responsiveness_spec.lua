-- Regression coverage for prompt responsiveness while a large delta burst is
-- delivered on Neovim's main loop. Before frame-based coalescing, each
-- on_delta call synchronously mutated and reparsed the growing output buffer,
-- delaying this key by well over a second on the same workload.

local h = dofile('tests/e2e/harness.lua')
local MiniTest = require('mini.test')
local uv = vim.uv or vim.loop

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = nil end,
    post_case = function()
      if _G.child then pcall(function() _G.child:close() end); _G.child = nil end
    end,
  },
})

T['prompt key is processed during a 1200-delta burst'] = function()
  _G.child = h.spawn({ lines = 30, columns = 100 })
  _G.child:lua([[
    require('cc.config').setup({
      streaming = { render_interval_ms = 33, markdown_hz = 5 },
      splash = false,
      statusline = { enabled = false },
    })
    local Output = require('cc.output')
    local Session = require('cc.session')
    local output = Output.new(Session.new(), 'cc-input-responsive-output')
    local output_buf = output:ensure_buffer()
    vim.api.nvim_set_current_buf(output_buf)
    output:set_window(vim.api.nvim_get_current_win())
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'text' })

    vim.cmd('belowright new')
    local prompt_buf = vim.api.nvim_get_current_buf()
    vim.bo[prompt_buf].buftype = 'nofile'
    vim.cmd('startinsert')

    _G._input_responsive = {
      output = output,
      prompt_buf = prompt_buf,
      started = false,
      queued = false,
    }
    local ns = vim.api.nvim_create_namespace('cc-input-responsive')
    vim.on_key(function(key)
      if key == 'x' and not _G._input_responsive.key_at_ns then
        _G._input_responsive.key_at_ns = vim.uv.hrtime()
      end
    end, ns)

    vim.defer_fn(function()
      _G._input_responsive.started = true
      for i = 1, 1200 do
        output:on_delta('text', ((i % 11 == 0) and '\n' or ' ') .. 'token')
      end
      _G._input_responsive.queued = true
    end, 200)
  ]])

  -- Give the deferred burst 50ms to start. The coalesced path has queued all
  -- deltas by then; the pre-fix synchronous renderer was still monopolizing
  -- the main loop for well over a second.
  _G.child:sleep(250)
  local sent_at = uv.hrtime()
  vim.rpcrequest(_G.child.chan, 'nvim_input', 'x')

  local processed = _G.child:wait_for(function(c)
    return c:lua([[
      return _G._input_responsive.key_at_ns ~= nil
        and vim.api.nvim_buf_get_lines(_G._input_responsive.prompt_buf, 0, 1, false)[1] == 'x'
    ]])
  end, 1000, 5)
  if not processed then error('prompt key was not processed within 1s') end

  local state = _G.child:lua([[
    return {
      started = _G._input_responsive.started,
      queued = _G._input_responsive.queued,
      key_at_ns = _G._input_responsive.key_at_ns,
    }
  ]])
  if not state.started or not state.queued then
    error('delta burst had not run before the key was measured')
  end

  local latency_ms = (state.key_at_ns - sent_at) / 1e6
  if latency_ms > 150 then
    error(string.format('prompt key processing took %.1fms (budget 150ms)', latency_ms))
  end
end

return T
