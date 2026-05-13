-- Tests for cc.meta_cache: persistent (mtime, size)-keyed metadata cache
-- backing history.list_in_dir.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Allocate a temp cache file path and a real JSONL fixture file. Resets
--- meta_cache to use the temp cache path. Returns { cache, jsonl }.
local function setup(child)
  return child.lua_get([[(function()
    local cache_path = vim.fn.tempname() .. '.json'
    local jsonl_path = vim.fn.tempname() .. '.jsonl'
    local f = io.open(jsonl_path, 'w')
    f:write(vim.json.encode({
      type = 'user',
      cwd = '/tmp/cc-meta-cache-test',
      message = { role = 'user', content = 'hello' },
    }) .. '\n')
    f:close()
    require('cc.meta_cache')._reset_for_tests(cache_path)
    return { cache = cache_path, jsonl = jsonl_path }
  end)()]])
end

-- ---------------------------------------------------------------------------
-- get / put basics
-- ---------------------------------------------------------------------------
T['get_put'] = MiniTest.new_set()

T['get_put']['round-trip returns stored meta'] = function()
  local paths = setup(_G.child)
  local meta = _G.child.lua_get(string.format([[(function()
    local cache = require('cc.meta_cache')
    local stat = vim.uv.fs_stat(%q)
    cache.put(%q, stat, { custom_title = 'hi', cwd = '/tmp/x' })
    return cache.get(%q, stat)
  end)()]], paths.jsonl, paths.jsonl, paths.jsonl))
  eq(meta.custom_title, 'hi')
  eq(meta.cwd, '/tmp/x')
end

T['get_put']['miss on unknown path returns nil'] = function()
  setup(_G.child)
  local result = _G.child.lua_get([[(function()
    local cache = require('cc.meta_cache')
    return cache.get('/nope.jsonl', { mtime = { sec = 0 }, size = 0 })
  end)()]])
  eq(result, vim.NIL)
end

T['get_put']['mtime mismatch is treated as miss'] = function()
  local paths = setup(_G.child)
  local result = _G.child.lua_get(string.format([[(function()
    local cache = require('cc.meta_cache')
    local stat = vim.uv.fs_stat(%q)
    cache.put(%q, stat, { custom_title = 'hi' })
    local fake = { mtime = { sec = stat.mtime.sec + 100 }, size = stat.size }
    return cache.get(%q, fake)
  end)()]], paths.jsonl, paths.jsonl, paths.jsonl))
  eq(result, vim.NIL)
end

T['get_put']['size mismatch is treated as miss'] = function()
  local paths = setup(_G.child)
  local result = _G.child.lua_get(string.format([[(function()
    local cache = require('cc.meta_cache')
    local stat = vim.uv.fs_stat(%q)
    cache.put(%q, stat, { custom_title = 'hi' })
    local fake = { mtime = { sec = stat.mtime.sec }, size = stat.size + 1 }
    return cache.get(%q, fake)
  end)()]], paths.jsonl, paths.jsonl, paths.jsonl))
  eq(result, vim.NIL)
end

-- ---------------------------------------------------------------------------
-- flush / load round-trip
-- ---------------------------------------------------------------------------
T['flush_load'] = MiniTest.new_set()

T['flush_load']['written cache survives a reset to the same path'] = function()
  local paths = setup(_G.child)
  local recovered = _G.child.lua_get(string.format([[(function()
    local cache = require('cc.meta_cache')
    local stat = vim.uv.fs_stat(%q)
    cache.put(%q, stat, { custom_title = 'persisted' })
    cache.flush()
    -- Simulate a fresh process: reset clears in-memory state but keeps the path.
    cache._reset_for_tests(%q)
    return cache.get(%q, stat)
  end)()]], paths.jsonl, paths.jsonl, paths.cache, paths.jsonl))
  eq(recovered.custom_title, 'persisted')
end

T['flush_load']['no-op when nothing is dirty'] = function()
  local paths = setup(_G.child)
  local exists = _G.child.lua_get(string.format([[(function()
    local cache = require('cc.meta_cache')
    cache.flush()
    return vim.uv.fs_stat(%q) ~= nil
  end)()]], paths.cache))
  eq(exists, false)
end

T['flush_load']['corrupt cache file yields empty load'] = function()
  local paths = setup(_G.child)
  local result = _G.child.lua_get(string.format([[(function()
    local f = io.open(%q, 'w')
    f:write('this is not json {{')
    f:close()
    local cache = require('cc.meta_cache')
    cache._reset_for_tests(%q)
    local stat = vim.uv.fs_stat(%q)
    return cache.get(%q, stat)
  end)()]], paths.cache, paths.cache, paths.jsonl, paths.jsonl))
  eq(result, vim.NIL)
end

T['flush_load']['version mismatch invalidates entries'] = function()
  local paths = setup(_G.child)
  local result = _G.child.lua_get(string.format([[(function()
    local f = io.open(%q, 'w')
    f:write(vim.json.encode({
      version = 9999,
      entries = { [%q] = { mtime = 1, size = 1, custom_title = 'old' } },
    }))
    f:close()
    local cache = require('cc.meta_cache')
    cache._reset_for_tests(%q)
    local stat = vim.uv.fs_stat(%q)
    return cache.get(%q, stat)
  end)()]], paths.cache, paths.jsonl, paths.cache, paths.jsonl, paths.jsonl))
  eq(result, vim.NIL)
end

-- ---------------------------------------------------------------------------
-- prune
-- ---------------------------------------------------------------------------
T['prune'] = MiniTest.new_set()

T['prune']['drops entries not in the live set'] = function()
  local paths = setup(_G.child)
  local result = _G.child.lua_get(string.format([[(function()
    local cache = require('cc.meta_cache')
    local stat = vim.uv.fs_stat(%q)
    cache.put(%q, stat, { custom_title = 'keep' })
    cache.put('/ghost.jsonl', stat, { custom_title = 'drop' })
    cache.prune({ [%q] = true })
    return {
      kept_title = (cache.get(%q, stat) or {}).custom_title,
      dropped_present = cache.get('/ghost.jsonl', stat) ~= nil,
    }
  end)()]], paths.jsonl, paths.jsonl, paths.jsonl, paths.jsonl))
  eq(result.kept_title, 'keep')
  eq(result.dropped_present, false)
end

-- ---------------------------------------------------------------------------
-- history._list_in_dir integration: cache hit avoids re-parsing
-- ---------------------------------------------------------------------------
T['integration'] = MiniTest.new_set()

T['integration']['second listing reuses cache (one _extract_metadata call)'] = function()
  -- Build a synthetic project dir with one session and verify that the
  -- second listing skips _extract_metadata via the cache.
  local result = _G.child.lua_get([[(function()
    local cache_path = vim.fn.tempname() .. '.json'
    local project_dir = vim.fn.tempname()
    vim.fn.mkdir(project_dir, 'p')
    local jsonl = project_dir .. '/abc.jsonl'
    local f = io.open(jsonl, 'w')
    f:write(vim.json.encode({
      type = 'user',
      cwd = '/tmp/integration',
      message = { role = 'user', content = 'first prompt' },
    }) .. '\n')
    f:close()

    require('cc.meta_cache')._reset_for_tests(cache_path)
    local history = require('cc.history')

    -- Spy on _extract_metadata.
    local original = history._extract_metadata
    local calls = 0
    history._extract_metadata = function(path)
      calls = calls + 1
      return original(path)
    end

    local first = history._list_in_dir(project_dir)
    local second = history._list_in_dir(project_dir)

    history._extract_metadata = original
    return {
      calls = calls,
      first_count = #first,
      second_count = #second,
      title = first[1] and first[1].title or nil,
    }
  end)()]])
  eq(result.calls, 1)
  eq(result.first_count, 1)
  eq(result.second_count, 1)
  eq(result.title, 'first prompt')
end

T['integration']['mtime change invalidates cache for that file'] = function()
  local result = _G.child.lua_get([[(function()
    local cache_path = vim.fn.tempname() .. '.json'
    local project_dir = vim.fn.tempname()
    vim.fn.mkdir(project_dir, 'p')
    local jsonl = project_dir .. '/abc.jsonl'
    local f = io.open(jsonl, 'w')
    f:write(vim.json.encode({
      type = 'user',
      message = { role = 'user', content = 'first' },
    }) .. '\n')
    f:close()

    require('cc.meta_cache')._reset_for_tests(cache_path)
    local history = require('cc.history')
    local original = history._extract_metadata
    local calls = 0
    history._extract_metadata = function(path)
      calls = calls + 1
      return original(path)
    end

    history._list_in_dir(project_dir) -- 1 parse

    -- Append a custom-title and bump mtime forward (utime is portable enough).
    history.append_custom_title(jsonl, 'abc', 'renamed')
    local stat = vim.uv.fs_stat(jsonl)
    -- Force the cached mtime to differ even if the test ran fast enough that
    -- mtime didn't advance to the next second.
    vim.uv.fs_utime(jsonl, stat.atime.sec, stat.mtime.sec + 5)

    history._list_in_dir(project_dir) -- 2nd parse (cache invalidated)

    history._extract_metadata = original
    return calls
  end)()]])
  eq(result, 2)
end

return T
