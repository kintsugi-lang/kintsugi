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
local function classify(n)
  if n == 0 then
    return "zero"
  elseif n == 1 then
    return "one"
  else
    local is_negative = n
    return "negative"
  else
    return "other"
  end
end
local function greeting(name, count)
  return "Hello, " .. name .. "! Count: " .. count .. " (doubled: " .. (count * 2) .. ")"
end
print(max_of(3, 7))
print(abs_of(-5))
print(squares_up_to(5))
print(split_even_odd({1, 2, 3, 4, 5}))
print(classify(-3))
print(greeting("Kintsugi", 42))
