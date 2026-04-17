-- Kintsugi runtime support
local function _prettify_inner(v)
  if v == nil then return "nil" end
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
  end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t ~= "table" then return tostring(v) end
  local mt = getmetatable(v)
  if mt ~= nil and mt.__tostring ~= nil then return tostring(v) end
  local n = #v
  local kc, isArray = 0, true
  for k, _ in pairs(v) do
    kc = kc + 1
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then
      isArray = false
    end
  end
  if isArray and kc == n then
    local parts = {}
    for i = 1, n do parts[i] = _prettify_inner(v[i]) end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  local parts = {}
  for k, val in pairs(v) do
    local ks
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
      ks = k
    else
      ks = "[" .. _prettify_inner(k) .. "]"
    end
    parts[#parts + 1] = ks .. " = " .. _prettify_inner(val)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end
local function _prettify(v)
  if type(v) == "string" then return v end
  return _prettify_inner(v)
end

local function max_of(a, b)
  if a > b then
    return a
  else
    return b
  end
end
local function abs_of(n)
  if n < 0 then
    return -(n)
  else
    return n
  end
end
local function squares_up_to(n)
  local _collect_r = {}
  for i = 1, n do
    _collect_r[#_collect_r+1] = i * i
  end
  return _collect_r
end
local function split_even_odd(blk)
  local _part_true = {}
  local _part_false = {}
  for _, x in ipairs(blk) do
    if (modulo) == 0 then
      _part_true[#_part_true+1] = x
    else
      _part_false[#_part_false+1] = x
    end
  end
  local _set_tmp = {_part_true, _part_false}
  local evens, odds = _set_tmp[1], _set_tmp[2]
  return {evens, odds}
end
local function is_negative(n)
  return n < 0
end
local function classify(n)
  if n == 0 then
    return "zero"
  elseif n == 1 then
    return "one"
  elseif is_negative(n) then
    return "negative"
  else
    return "other"
  end
end
local function greeting(name, count)
  return "Hello, " .. name .. "! Count: " .. count .. " (doubled: " .. (count * 2) .. ")"
end
print(_prettify(max_of(3, 7)))
print(_prettify(abs_of(-5)))
print(_prettify(squares_up_to(5)))
print(_prettify(split_even_odd({1, 2, 3, 4, 5})))
print(_prettify(classify(-3)))
print(_prettify(greeting("Kintsugi", 42)))
