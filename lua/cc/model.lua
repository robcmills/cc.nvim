-- Model-name discovery and conservative fuzzy resolution.
--
-- Provider model IDs are awkward to type, so cc.nvim accepts unambiguous
-- suffixes and small typos (for example `sol` or `soll` →
-- `gpt-5.6-sol`). Configured models are preferred over built-in fallbacks,
-- allowing a user's setup to move a shorthand to a newer model generation.

local M = {}

local BUILTINS = {
  { provider = 'claude', name = 'fable' },
  { provider = 'claude', name = 'haiku' },
  { provider = 'claude', name = 'opus' },
  { provider = 'claude', name = 'sonnet' },
  { provider = 'codex', name = 'gpt-5.6-sol' },
  { provider = 'codex', name = 'gpt-5.6-luna' },
}

local function trim(value)
  return type(value) == 'string' and (value:match('^%s*(.-)%s*$') or '') or ''
end

local function compact(value)
  return value:lower():gsub('[^%w]', '')
end

local function tail(value)
  return value:lower():match('([^%-%./]+)$') or value:lower()
end

local function levenshtein(a, b)
  if a == b then return 0 end
  if #a == 0 then return #b end
  if #b == 0 then return #a end
  local previous = {}
  for j = 0, #b do previous[j] = j end
  for i = 1, #a do
    local current = { [0] = i }
    for j = 1, #b do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      current[j] = math.min(
        current[j - 1] + 1,
        previous[j] + 1,
        previous[j - 1] + cost)
    end
    previous = current
  end
  return previous[#b]
end

---@class cc.ModelCandidate
---@field name string
---@field provider 'claude'|'codex'
---@field priority integer

---@return cc.ModelCandidate[]
function M.candidates()
  local by_key = {}
  local out = {}
  local function add(provider, name, priority)
    name = trim(name)
    if name == '' then return end
    local key = provider .. '\0' .. name:lower()
    local existing = by_key[key]
    if existing then
      existing.priority = math.min(existing.priority, priority)
      return
    end
    local candidate = { provider = provider, name = name, priority = priority }
    by_key[key] = candidate
    table.insert(out, candidate)
  end

  local providers = require('cc.config').options.providers or {}
  for _, provider in ipairs({ 'claude', 'codex' }) do
    local opts = providers[provider] or {}
    add(provider, opts.model, 0)
    add(provider, opts.auto_rename_model, 5)
  end
  for _, candidate in ipairs(BUILTINS) do
    add(candidate.provider, candidate.name, 10)
  end

  table.sort(out, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    if a.provider ~= b.provider then return a.provider < b.provider end
    return a.name < b.name
  end)
  return out
end

local function unique_best(matches)
  if #matches == 0 then return nil, {} end
  table.sort(matches, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    if a.candidate.priority ~= b.candidate.priority then
      return a.candidate.priority < b.candidate.priority
    end
    return a.candidate.name < b.candidate.name
  end)
  local best_score = matches[1].score
  local best_priority = matches[1].candidate.priority
  local best = {}
  for _, match in ipairs(matches) do
    if match.score == best_score and match.candidate.priority == best_priority then
      table.insert(best, match.candidate)
    end
  end
  return #best == 1 and best[1] or nil, best
end

--- Resolve a model name, shorthand, or small typo.
---@param input any
---@return string? model
---@return 'claude'|'codex'|nil provider
---@return 'exact'|'shorthand'|'fuzzy'|'ambiguous'|'unknown' status
---@return string[] suggestions
function M.resolve(input)
  local raw = trim(input)
  if raw == '' then return nil, nil, 'unknown', {} end
  local query = raw:lower()
  local query_compact = compact(query)
  local candidates = M.candidates()

  for _, candidate in ipairs(candidates) do
    if candidate.name:lower() == query then
      return candidate.name, candidate.provider, 'exact', {}
    end
  end

  local exact_forms = {}
  for _, candidate in ipairs(candidates) do
    if tail(candidate.name) == query or compact(candidate.name) == query_compact then
      table.insert(exact_forms, { candidate = candidate, score = 0 })
    end
  end
  local exact, exact_ties = unique_best(exact_forms)
  if exact then return exact.name, exact.provider, 'shorthand', {} end
  if #exact_ties > 1 then
    local names = {}
    for _, candidate in ipairs(exact_ties) do table.insert(names, candidate.name) end
    return nil, nil, 'ambiguous', names
  end

  -- Prefix/substring shorthand is only automatic when exactly one candidate
  -- matches. Requiring three characters avoids guesses such as `so`, which
  -- could mean either `sol` or `sonnet`.
  if #query >= 3 then
    local partial = {}
    for _, candidate in ipairs(candidates) do
      local name, suffix = candidate.name:lower(), tail(candidate.name)
      if name:sub(1, #query) == query
          or suffix:sub(1, #query) == query
          or name:find(query, 1, true) then
        table.insert(partial, candidate)
      end
    end
    if #partial == 1 then
      return partial[1].name, partial[1].provider, 'shorthand', {}
    elseif #partial > 1 then
      local names = {}
      for _, candidate in ipairs(partial) do table.insert(names, candidate.name) end
      table.sort(names)
      return nil, nil, 'ambiguous', names
    end
  end

  local fuzzy = {}
  for _, candidate in ipairs(candidates) do
    local name_compact = compact(candidate.name)
    local suffix = tail(candidate.name)
    local distance = math.min(
      levenshtein(query_compact, name_compact),
      levenshtein(query, suffix))
    local threshold = #query >= 8 and 2 or 1
    if #query >= 3 and distance <= threshold then
      table.insert(fuzzy, { candidate = candidate, score = distance })
    end
  end
  local fuzzy_match, fuzzy_ties = unique_best(fuzzy)
  if fuzzy_match then
    return fuzzy_match.name, fuzzy_match.provider, 'fuzzy', {}
  end
  if #fuzzy_ties > 1 then
    local names = {}
    for _, candidate in ipairs(fuzzy_ties) do table.insert(names, candidate.name) end
    return nil, nil, 'ambiguous', names
  end

  return raw, nil, 'unknown', {}
end

local function completion_score(query, candidate)
  if query == '' then return candidate.priority * 100 end
  local name = candidate.name:lower()
  local suffix = tail(candidate.name)
  local query_compact = compact(query)
  if name == query or suffix == query then return 0 + candidate.priority end
  if suffix:sub(1, #query) == query then return 10 + (#suffix - #query) end
  if name:sub(1, #query) == query then return 20 + (#name - #query) end
  local pos = name:find(query, 1, true)
  if pos then return 30 + pos end
  local distance = math.min(
    levenshtein(query, suffix),
    levenshtein(query_compact, compact(name)))
  local threshold = #query >= 8 and 3 or 2
  if #query >= 2 and distance <= threshold then return 50 + distance end
  return nil
end

--- Fuzzy-ranked model names for command-line completion.
---@param query string?
---@param provider 'claude'|'codex'|nil
---@return string[]
function M.complete(query, provider)
  query = trim(query):lower()
  local ranked = {}
  for _, candidate in ipairs(M.candidates()) do
    if not provider or candidate.provider == provider then
      local score = completion_score(query, candidate)
      if score then table.insert(ranked, { name = candidate.name, score = score }) end
    end
  end
  table.sort(ranked, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return a.name < b.name
  end)
  local out = {}
  for _, item in ipairs(ranked) do table.insert(out, item.name) end
  return out
end

M._levenshtein = levenshtein

return M
