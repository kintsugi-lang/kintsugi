-- Kintsugi runtime support
local function _copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end
local function _append(t, v)
  if type(v) == "table" then
    for i = 1, #v do t[#t+1] = v[i] end
  else
    t[#t+1] = v
  end
  return t
end
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

print("Hello, Kintsugi!")
local function add(a, b)
  return a + b
end
print("2 + 3 = " .. add(2, 3))
local _collect_r = {}
for n = 1, 5 do
  _collect_r[#_collect_r+1] = n * n
end
local squares = _collect_r
print("Squares: " .. _prettify(squares))
local function qsort(blk)
  if #blk <= 1 then
    return blk
  end
  local pivot = blk[1]
  local rest = _copy(blk)
  table.remove(rest, 1)
  local _part_true = {}
  local _part_false = {}
  for _, x in ipairs(rest) do
    if x < pivot then
      _part_true[#_part_true+1] = x
    else
      _part_false[#_part_false+1] = x
    end
  end
  local _set_tmp = {_part_true, _part_false}
  local lo, hi = _set_tmp[1], _set_tmp[2]
  local result = qsort(lo)
  _append(result, pivot)
  for _, x in ipairs(qsort(hi)) do
    _append(result, x)
  end
  return result
end
print("Sorted: " .. _prettify(qsort({3, 1, 4, 1, 5, 9, 2, 6})))
