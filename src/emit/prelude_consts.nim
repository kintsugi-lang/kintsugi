import std/strutils

## Runtime support helpers emitted into prelude.lua.
##
## Each constant is a standalone Lua function or setup block. buildPrelude
## in lua.nim picks the subset actually referenced by the compiled program
## (tracked via e.usedHelpers) and writes them in dependency order.
##
## Kept out of lua.nim so the emitter source stays smaller and these
## strings can be read without scrolling past 4000 lines of emission code.

const PreludeUnpack* = "unpack = unpack or table.unpack\n"

const PreludeNone* = """_NONE = setmetatable({}, {__tostring = function() return "nil" end})
function _is_none(v) return v == nil or v == _NONE end
"""

const PreludeDeepCopy* = """function _deep_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}; for k, v in pairs(t) do r[k] = _deep_copy(v) end; return r
end
"""

const PreludeMoney* = """_money_mt = {}
function _money(cents) return setmetatable({cents = cents}, _money_mt) end
_money_mt.__add = function(a, b) return _money(a.cents + b.cents) end
_money_mt.__sub = function(a, b) return _money(a.cents - b.cents) end
_money_mt.__mul = function(a, b)
  local n = type(a) == "number" and a or b
  local c = type(a) == "table" and a.cents or b.cents
  return _money(math.floor(n * c + 0.5))
end
_money_mt.__div = function(a, b)
  if type(b) == "number" then return _money(math.floor(a.cents / b + 0.5)) end
  return a.cents / b.cents
end
_money_mt.__unm = function(a) return _money(-a.cents) end
_money_mt.__eq  = function(a, b) return a.cents == b.cents end
_money_mt.__lt  = function(a, b) return a.cents < b.cents end
_money_mt.__le  = function(a, b) return a.cents <= b.cents end
_money_mt.__tostring = function(m)
  local neg = m.cents < 0
  local abs_c = math.abs(m.cents)
  local d = math.floor(abs_c / 100)
  local c = abs_c % 100
  return (neg and "-" or "") .. "$" .. d .. "." .. (c < 10 and ("0"..c) or tostring(c))
end
_money_mt.__concat = function(a, b) return tostring(a) .. tostring(b) end
"""

const PreludePair* = """_pair_mt = {}
_pair_mt.__add = function(a, b) return setmetatable({x=a.x+b.x, y=a.y+b.y}, _pair_mt) end
_pair_mt.__sub = function(a, b) return setmetatable({x=a.x-b.x, y=a.y-b.y}, _pair_mt) end
_pair_mt.__mul = function(a, b)
  if type(a) == "number" then return setmetatable({x=a*b.x, y=a*b.y}, _pair_mt) end
  if type(b) == "number" then return setmetatable({x=a.x*b, y=a.y*b}, _pair_mt) end
  return setmetatable({x=a.x*b.x, y=a.y*b.y}, _pair_mt)
end
_pair_mt.__div = function(a, b)
  if type(b) == "number" then return setmetatable({x=a.x/b, y=a.y/b}, _pair_mt) end
  return setmetatable({x=a.x/b.x, y=a.y/b.y}, _pair_mt)
end
_pair_mt.__unm = function(a) return setmetatable({x=-a.x, y=-a.y}, _pair_mt) end
_pair_mt.__eq  = function(a, b) return a.x == b.x and a.y == b.y end
_pair_mt.__tostring = function(a) return "{x = " .. tostring(a.x) .. ", y = " .. tostring(a.y) .. "}" end
function _pair(x, y) return setmetatable({x=x, y=y}, _pair_mt) end
"""

const PreludePrettify* = """function _prettify(v, inner)
  if v == nil then return "nil" end
  local t = type(v)
  if t == "string" then return inner and ('"'..v:gsub('"', '\\"')..'"') or v end
  if t ~= "table" then return tostring(v) end
  local mt = getmetatable(v); if mt and mt.__tostring then return tostring(v) end
  local n, kc, parts = #v, 0, {}
  for k in pairs(v) do
    kc = kc + 1
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > n then kc = -1 end
  end
  if kc == n then
    for i = 1, n do parts[i] = _prettify(v[i], true) end
    return "{"..table.concat(parts, ", ").."}"
  end
  for k, val in pairs(v) do
    local ks = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or "["..tostring(k).."]"
    parts[#parts+1] = ks.." = ".._prettify(val, true)
  end
  return "{"..table.concat(parts, ", ").."}"
end
"""

const PreludeCapture* = """function _capture(data, specs)
  local keywords, spec_map = {}, {}
  for _, s in ipairs(specs) do
    local name, exact = s, -1
    if type(s) == "table" then name, exact = s[1], s[2] end
    keywords[name] = true
    spec_map[name] = exact
  end
  local result, i = {}, 1
  while i <= #data do
    local val = data[i]
    if type(val) == "string" and spec_map[val] ~= nil then
      local name, exact = val, spec_map[val]
      i = i + 1
      if exact >= 0 then
        local cap = {}
        for j = 1, exact do if i <= #data then cap[#cap+1] = data[i]; i = i + 1 end end
        if result[name] == nil then
          if #cap == 1 then result[name] = cap[1] else result[name] = cap end
        else
          if type(result[name]) ~= "table" then result[name] = {result[name]} end
          for _, v in ipairs(cap) do result[name][#result[name]+1] = v end
        end
      else
        local cap = {}
        while i <= #data do
          local cur = data[i]
          if type(cur) == "string" and keywords[cur] and cur ~= name then break end
          if type(cur) == "string" and cur == name then i = i + 1
          else cap[#cap+1] = cur; i = i + 1 end
        end
        if #cap == 1 then result[name] = cap[1] elseif #cap > 1 then result[name] = cap end
      end
    else i = i + 1 end
  end
  return result
end
"""

const PreludeEquals* = """function _equals(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if #a ~= #b then return false end
  for i = 1, #a do if not _equals(a[i], b[i]) then return false end end
  return true
end
"""

const PreludeHas* = """function _has(t, v)
  for _, x in ipairs(t) do if _equals(x, v) then return true end end
  return false
end
"""

const PreludeReplace* = """function _replace(s, old, new)
  local i, j = s:find(old, 1, true)
  if not i then return s end
  local r = {}
  local p = 1
  while i do
    r[#r+1] = s:sub(p, i - 1)
    r[#r+1] = new
    p = j + 1
    i, j = s:find(old, p, true)
  end
  r[#r+1] = s:sub(p)
  return table.concat(r)
end
"""

const PreludeSelect* = """function _select(t, key)
  if type(t) == "table" and t[key] ~= nil then return t[key] end
  if type(t) == "table" then
    for i = 1, #t - 1 do if _equals(t[i], key) then return t[i + 1] end end
  end
  return nil
end
"""

const PreludeCopy* = """function _copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end
"""

const PreludeAppend* = """function _append(t, v)
  if type(v) == "table" then
    for i = 1, #v do t[#t+1] = v[i] end
  else
    t[#t+1] = v
  end
  return t
end
"""

const PreludeSplit* = """function _split(s, d)
  local r = {}
  if d == "" then
    for i = 1, #s do r[#r+1] = s:sub(i, i) end
    return r
  end
  local p = 1
  while true do
    local i, j = s:find(d, p, true)
    if not i then r[#r+1] = s:sub(p); break end
    r[#r+1] = s:sub(p, i - 1)
    p = j + 1
  end
  return r
end
"""

const PreludeInsert* = """function _insert(x, v, i)
  if type(x) == "string" then
    return x:sub(1, i - 1) .. v .. x:sub(i)
  end
  table.insert(x, i, v)
  return x
end
"""

const PreludeRemove* = """function _remove(x, i)
  if type(x) == "string" then
    return x:sub(1, i - 1) .. x:sub(i + 1)
  end
  table.remove(x, i)
  return x
end
"""

const PreludeSort* = """function _sort(x)
  if type(x) == "string" then
    local t = {}
    for i = 1, #x do t[i] = x:sub(i, i) end
    table.sort(t)
    return table.concat(t)
  end
  table.sort(x)
  return x
end
"""

const PreludeSubset* = """function _subset(x, s, n)
  if type(x) == "string" then
    return string.sub(x, s, s + n - 1)
  end
  local r = {}
  local stop = math.min(s + n - 1, #x)
  for i = s, stop do r[#r+1] = x[i] end
  return r
end
"""

const PreludeMake* = """function _make(proto, overrides, typeName)
  local inst = {}
  for k, v in pairs(proto) do inst[k] = v end
  if overrides then for k, v in pairs(overrides) do inst[k] = v end end
  if typeName then inst._type = typeName end
  return inst
end
"""

## Prelude helper registry — demand-driven emission in dependency order.
##
## buildPrelude iterates this table and emits any entry whose `useFlag`
## name appears in e.usedHelpers. Listed in the correct emission order
## (dependencies before dependents; ordering matches the Phase 0 file
## output exactly so goldens stay byte-identical). Adding a new helper:
## append one entry here — buildPrelude doesn't change.
##
## `useFlag` is the name the emitter tracks in `usedHelpers`. Two flags
## can share the same body (e.g., _NONE and _is_none both pull in
## PreludeNone); the `key` field de-duplicates.
type PreludeEntry* = object
  key*: string        ## de-dup key across flags; body emitted once per key
  useFlags*: seq[string]  ## any of these present in usedHelpers triggers this body
  body*: string

const PreludeRegistry* = @[
  PreludeEntry(key: "_none",     useFlags: @["_NONE", "_is_none"],
               body: PreludeNone.strip),
  PreludeEntry(key: "_deep_copy", useFlags: @["_deep_copy"],
               body: PreludeDeepCopy.strip),
  PreludeEntry(key: "_money",    useFlags: @["_money"],
               body: PreludeMoney.strip),
  PreludeEntry(key: "_pair",     useFlags: @["_pair"],
               body: PreludePair.strip),
  PreludeEntry(key: "_capture",  useFlags: @["_capture"],
               body: PreludeCapture.strip),
  PreludeEntry(key: "_equals",   useFlags: @["_equals"],
               body: PreludeEquals.strip),
  PreludeEntry(key: "_has",      useFlags: @["_has"],
               body: PreludeHas.strip),
  PreludeEntry(key: "_replace",  useFlags: @["_replace"],
               body: PreludeReplace.strip),
  PreludeEntry(key: "_select",   useFlags: @["_select"],
               body: PreludeSelect.strip),
  PreludeEntry(key: "_copy",     useFlags: @["_copy"],
               body: PreludeCopy.strip),
  PreludeEntry(key: "_append",   useFlags: @["_append"],
               body: PreludeAppend.strip),
  PreludeEntry(key: "_split",    useFlags: @["_split"],
               body: PreludeSplit.strip),
  PreludeEntry(key: "_subset",   useFlags: @["_subset"],
               body: PreludeSubset.strip),
  PreludeEntry(key: "_sort",     useFlags: @["_sort"],
               body: PreludeSort.strip),
  PreludeEntry(key: "_insert",   useFlags: @["_insert"],
               body: PreludeInsert.strip),
  PreludeEntry(key: "_remove",   useFlags: @["_remove"],
               body: PreludeRemove.strip),
  PreludeEntry(key: "_make",     useFlags: @["_make"],
               body: PreludeMake.strip),
  PreludeEntry(key: "_prettify", useFlags: @["_prettify"],
               body: PreludePrettify.strip),
]
