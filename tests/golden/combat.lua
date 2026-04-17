-- Kintsugi runtime support
math.randomseed(os.time())
local _NONE = setmetatable({}, {__tostring = function() return "nil" end})
local function _is_none(v) return v == nil or v == _NONE end
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

local slash = {
  name = "Slash",
  power = 25,
  kind = "physical"
}
local fireball = {
  name = "Fireball",
  power = 30,
  kind = "fire"
}
local heal = {
  name = "Heal",
  power = 20,
  kind = "heal"
}
local poison = {
  name = "Poison",
  power = 8,
  kind = "dot"
}
local function make_warrior(n)
  return {
    name = n,
    hp = 100,
    max_hp = 100,
    attack = 15,
    defense = 10,
    speed = 8,
    abilities = {"slash"}
  }
end
local function make_mage(n)
  return {
    name = n,
    hp = 70,
    max_hp = 70,
    attack = 8,
    defense = 5,
    speed = 12,
    abilities = {"fireball", "poison"}
  }
end
local function make_healer(n)
  return {
    name = n,
    hp = 80,
    max_hp = 80,
    attack = 6,
    defense = 8,
    speed = 10,
    abilities = {"heal", "slash"}
  }
end
local function is_alive(unit)
  return unit.hp > 0
end
local function clamp(val, lo, hi)
  if val < lo then
    return lo
  end
  if val > hi then
    return hi
  end
  return val
end
local function calc_damage(attacker, ability, defender)
  local dmg = attacker.attack + ability.power - defender.defense
  if dmg < 1 then
    dmg = 1
  end
  return dmg
end
local function apply_ability(user, ability, target)
  if ability.kind == "heal" then
    local amount = clamp(ability.power, 0, (target.max_hp - target.hp))
    target.hp = target.hp + amount
    print("  " .. user.name .. " heals " .. target.name .. " for " .. amount .. " HP (" .. target.hp .. "/" .. target.max_hp .. ")")
  elseif ability.kind == "dot" then
    local dmg = ability.power
    target.hp = target.hp - dmg
    if target.hp < 0 then
      target.hp = 0
    end
    print("  " .. user.name .. " poisons " .. target.name .. " for " .. dmg .. " damage (" .. target.hp .. "/" .. target.max_hp .. ")")
  else
    local dmg = calc_damage(user, ability, target)
    target.hp = target.hp - dmg
    if target.hp < 0 then
      target.hp = 0
    end
    print("  " .. user.name .. " uses " .. ability.name .. " on " .. target.name .. " for " .. dmg .. " damage (" .. target.hp .. "/" .. target.max_hp .. ")")
  end
end
local function pick_enemy(enemies)
  local _collect_r = {}
  for _, e in ipairs(enemies) do
    if is_alive(e) then
      _collect_r[#_collect_r+1] = e
    end
  end
  local living = _collect_r
  if (#living == 0) then
    return _NONE
  end
  return living[math.random(#living)]
end
local function pick_wounded(allies)
  local _collect_r = {}
  for _, a in ipairs(allies) do
    if (is_alive(a) and a.hp < a.max_hp) then
      _collect_r[#_collect_r+1] = a
    end
  end
  local wounded = _collect_r
  if (#wounded == 0) then
    return _NONE
  end
  return wounded[math.random(#wounded)]
end
local function pick_action(unit, allies, enemies)
  local _has_r = false
  for _, x in ipairs(unit.abilities) do if x == "heal" then _has_r = true; break end end
  if _has_r then
    local w = pick_wounded(allies)
    if (not _is_none(w)) then
      return {
        ability = heal,
        target = w
      }
    end
  end
  local ability_name = unit.abilities[math.random(#unit.abilities)]
  local target = pick_enemy(enemies)
  if _is_none(target) then
    return _NONE
  end
  if ability_name == "slash" then
    return {
      ability = slash,
      target = target
    }
  elseif ability_name == "fireball" then
    return {
      ability = fireball,
      target = target
    }
  elseif ability_name == "poison" then
    return {
      ability = poison,
      target = target
    }
  elseif ability_name == "heal" then
    return {
      ability = heal,
      target = target
    }
  else
    return {
      ability = slash,
      target = target
    }
  end
end
local function turn_order(all_units)
  local _key = function(u)
    return -(u.speed)
  end
  table.sort(all_units, function(a, b) return _key(a) < _key(b) end)
  return all_units
end
local function count_alive(team)
  local n = 0
  for _, u in ipairs(team) do
    if is_alive(u) then
      n = n + 1
    end
  end
  return n
end
local team_a = {make_warrior("Kael"), make_mage("Lyra"), make_healer("Mira")}
local team_b = {make_warrior("Grok"), make_mage("Zara"), make_healer("Nix")}
local all_units = {team_a[1], team_a[2], team_a[#team_a], team_b[1], team_b[2], team_b[#team_b]}
local function name_of(unit)
  return unit.name
end
local function print_team(label, team)
  print(_prettify(label .. name_of(team[1]) .. ", " .. name_of(team[2]) .. ", " .. name_of(team[#team])))
end
print("=== BATTLE START ===")
print_team("Team A: ", team_a)
print_team("Team B: ", team_b)
print("")
local turn = 0
while true do
  turn = turn + 1
  print("--- Round " .. turn .. " ---")
  local ordered = turn_order(all_units)
  for _, unit in ipairs(ordered) do
    if is_alive(unit) then
      local is_team_a = (unit.name == name_of(team_a[1]) or unit.name == name_of(team_a[2]) or unit.name == name_of(team_a[#team_a]))
      local allies
      if is_team_a then
        allies = team_a
      else
        allies = team_b
      end
      local enemies
      if is_team_a then
        enemies = team_b
      else
        enemies = team_a
      end
      if count_alive(enemies) > 0 then
        local action = pick_action(unit, allies, enemies)
        if (not _is_none(action)) then
          apply_ability(unit, action.ability, action.target)
          if not (is_alive(action.target)) then
            print("  ** " .. _prettify(action.target.name) .. " is knocked out! **")
          end
        end
      end
    end
  end
  local a_alive = count_alive(team_a)
  local b_alive = count_alive(team_b)
  print("  Team A alive: " .. a_alive .. "  Team B alive: " .. b_alive)
  print("")
  if a_alive == 0 then
    print("=== TEAM B WINS ===")
    break
  end
  if b_alive == 0 then
    print("=== TEAM A WINS ===")
    break
  end
  if turn >= 20 then
    print("=== DRAW (20 rounds) ===")
    break
  end
end
