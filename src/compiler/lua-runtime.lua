-- ============================================================
-- Kintsugi Runtime Library for Lua 5.1
-- ============================================================
-- Tier 3 functions that can't be statically compiled.
-- Shipped alongside compiled Kintsugi/Lua programs.

local ktg = {}

-- ============================================================
-- Value helpers
-- ============================================================

function ktg.is_truthy(v)
  return v ~= nil and v ~= false
end

function ktg.type_of(v)
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) then return "integer!" end
    return "float!"
  elseif t == "string" then return "string!"
  elseif t == "boolean" then return "logic!"
  elseif t == "nil" then return "none!"
  elseif t == "table" then
    if v.__ktg_type then return v.__ktg_type end
    return "block!"
  elseif t == "function" then return "function!"
  end
  return "any!"
end

-- ============================================================
-- Block operations
-- ============================================================

function ktg.copy(t)
  if type(t) == "string" then return t end
  local r = {}
  for i, v in ipairs(t) do r[i] = v end
  return r
end

function ktg.append(t, v)
  table.insert(t, v)
  return t
end

function ktg.select(t, key)
  if type(t) == "table" then
    for i = 1, #t - 1 do
      if t[i] == key then return t[i + 1] end
    end
    if t[key] ~= nil then return t[key] end
  end
  return nil
end

function ktg.has(t, v)
  if type(t) == "string" then
    return string.find(t, v, 1, true) ~= nil
  end
  if type(t) == "table" then
    for _, item in ipairs(t) do
      if item == v then return true end
    end
  end
  return false
end

function ktg.index_of(t, v)
  if type(t) == "string" then
    return string.find(t, v, 1, true)
  end
  for i, item in ipairs(t) do
    if item == v then return i end
  end
  return nil
end

-- ============================================================
-- String operations
-- ============================================================

function ktg.trim(s)
  return s:match("^%s*(.-)%s*$")
end

function ktg.split(s, delim)
  local result = {}
  for part in s:gmatch("([^" .. delim .. "]+)") do
    result[#result + 1] = part
  end
  return result
end

function ktg.rejoin(t)
  local parts = {}
  for _, v in ipairs(t) do
    parts[#parts + 1] = tostring(v)
  end
  return table.concat(parts)
end

-- ============================================================
-- Result construction
-- ============================================================

function ktg.make_result(ok, value, kind, message, data)
  return {
    __ktg_type = "block!",
    "ok:", ok,
    "value:", value,
    "kind:", kind,
    "message:", message,
    "data:", data,
  }
end

-- ============================================================
-- Compose — walk a block, evaluate parens, leave rest
-- ============================================================
-- In compiled mode, compose operates on block-as-data.
-- Parens in the block are tables tagged with __ktg_type = "paren!".
-- Since parens are already evaluated at compile time in most cases,
-- this is primarily for runtime compose via Tier 3.

function ktg.compose(block, eval_fn)
  local result = {}
  for _, v in ipairs(block) do
    if type(v) == "table" and v.__ktg_type == "paren!" then
      -- Evaluate the paren contents
      if eval_fn then
        result[#result + 1] = eval_fn(v)
      else
        result[#result + 1] = v
      end
    elseif type(v) == "table" and v.__ktg_type ~= "paren!" then
      -- Recurse into sub-blocks
      result[#result + 1] = ktg.compose(v, eval_fn)
    else
      result[#result + 1] = v
    end
  end
  return result
end

-- ============================================================
-- Reduce — evaluate each expression in a block
-- ============================================================
-- In compiled mode, this requires an eval function.
-- For static blocks, the compiler can inline the evaluations.

function ktg.reduce(block, eval_fn)
  if not eval_fn then return ktg.copy(block) end
  local result = {}
  for _, v in ipairs(block) do
    result[#result + 1] = eval_fn(v)
  end
  return result
end

-- ============================================================
-- Parse — block and string matching
-- ============================================================
-- This is a simplified parse implementation for Lua.
-- Covers the core combinators needed at runtime.

local parse = {}

-- Character class checkers
parse.char_classes = {
  alpha = function(ch) return ch:match("[%a]") ~= nil end,
  digit = function(ch) return ch:match("[%d]") ~= nil end,
  alnum = function(ch) return ch:match("[%w]") ~= nil end,
  space = function(ch) return ch:match("[%s]") ~= nil end,
  upper = function(ch) return ch:match("[%u]") ~= nil end,
  lower = function(ch) return ch:match("[%l]") ~= nil end,
}

-- Parse a string against rules
-- rules is a table of rule elements
-- Returns: matched (bool), captures (table)
function ktg.parse_string(input, rules)
  local captures = {}
  local pos = parse.match_sequence(input, 1, rules, 1, captures, "string")
  if pos and pos > #input then
    return true, captures
  end
  return false, captures
end

-- Parse a block against rules
function ktg.parse_block(input, rules)
  local captures = {}
  local pos = parse.match_sequence(input, 1, rules, 1, captures, "block")
  if pos and pos > #input then
    return true, captures
  end
  return false, captures
end

function parse.match_sequence(input, ipos, rules, rpos, captures, mode)
  -- Split on | first
  local alternatives = parse.split_on_pipe(rules)
  if #alternatives > 1 then
    for _, alt in ipairs(alternatives) do
      local result = parse.match_seq_inner(input, ipos, alt, 1, captures, mode)
      if result then return result end
    end
    return nil
  end
  return parse.match_seq_inner(input, ipos, rules, rpos, captures, mode)
end

function parse.match_seq_inner(input, ipos, rules, rpos, captures, mode)
  while rpos <= #rules do
    local rule = rules[rpos]

    -- Sub-rule table (block)
    if type(rule) == "table" then
      local result = parse.match_sequence(input, ipos, rule, 1, captures, mode)
      if not result then return nil end
      ipos = result
      rpos = rpos + 1

    -- String literal
    elseif type(rule) == "string" then
      if mode == "string" then
        if input:sub(ipos, ipos + #rule - 1) == rule then
          ipos = ipos + #rule
        else
          return nil
        end
      else
        if input[ipos] == rule then
          ipos = ipos + 1
        else
          return nil
        end
      end
      rpos = rpos + 1

    -- Word/keyword
    elseif rule == "skip" then
      if ipos > #input then return nil end
      ipos = ipos + 1
      rpos = rpos + 1

    elseif rule == "end" then
      if mode == "string" then
        if ipos > #input then rpos = rpos + 1 else return nil end
      else
        if ipos > #input then rpos = rpos + 1 else return nil end
      end

    elseif rule == "some" then
      rpos = rpos + 1
      local count = 0
      while true do
        local r = parse.match_one(input, ipos, rules, rpos, captures, mode)
        if not r or r == ipos then break end
        ipos = r
        count = count + 1
      end
      if count == 0 then return nil end
      rpos = rpos + 1

    elseif rule == "any" then
      rpos = rpos + 1
      while true do
        local r = parse.match_one(input, ipos, rules, rpos, captures, mode)
        if not r or r == ipos then break end
        ipos = r
      end
      rpos = rpos + 1

    elseif rule == "opt" then
      rpos = rpos + 1
      local r = parse.match_one(input, ipos, rules, rpos, captures, mode)
      if r then ipos = r end
      rpos = rpos + 1

    elseif parse.char_classes[rule] and mode == "string" then
      if ipos > #input then return nil end
      if parse.char_classes[rule](input:sub(ipos, ipos)) then
        ipos = ipos + 1
      else
        return nil
      end
      rpos = rpos + 1

    else
      -- Unknown rule, skip
      rpos = rpos + 1
    end
  end
  return ipos
end

function parse.match_one(input, ipos, rules, rpos, captures, mode)
  local rule = rules[rpos]
  if not rule then return nil end

  if type(rule) == "table" then
    return parse.match_sequence(input, ipos, rule, 1, captures, mode)
  end

  if type(rule) == "string" then
    if mode == "string" then
      if input:sub(ipos, ipos + #rule - 1) == rule then
        return ipos + #rule
      end
    else
      if input[ipos] == rule then return ipos + 1 end
    end
    return nil
  end

  if rule == "skip" then
    if ipos <= #input then return ipos + 1 end
    return nil
  end

  if parse.char_classes[rule] and mode == "string" then
    if ipos > #input then return nil end
    if parse.char_classes[rule](input:sub(ipos, ipos)) then
      return ipos + 1
    end
    return nil
  end

  return nil
end

function parse.split_on_pipe(rules)
  local alternatives = {}
  local current = {}
  for _, rule in ipairs(rules) do
    if rule == "|" then
      alternatives[#alternatives + 1] = current
      current = {}
    else
      current[#current + 1] = rule
    end
  end
  alternatives[#alternatives + 1] = current
  if #alternatives == 1 then return {rules} end
  return alternatives
end

-- ============================================================
-- Export
-- ============================================================

ktg.parse = parse
return ktg
