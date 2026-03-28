-- Kintsugi runtime support
local unpack = unpack or table.unpack
local _NONE = setmetatable({}, {__tostring = function() return "none" end})
local function _is_none(v) return v == nil or v == _NONE end
local function _deep_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}; for k, v in pairs(t) do r[k] = _deep_copy(v) end; return r
end
local cell_size = 140
local padding = 10
local offset = 20
local line_width = 4
local bg = {0.12, 0.12, 0.18}
local grid = {0.35, 0.35, 0.45}
local x_clr = {0.95, 0.3, 0.3}
local o_clr = {0.3, 0.55, 0.95}
local txt = {0.9, 0.9, 0.9}
local win = {0.3, 0.95, 0.45}
local drw = {0.85, 0.85, 0.3}
local board = {
  cells = {_NONE, _NONE, _NONE, _NONE, _NONE, _NONE, _NONE, _NONE, _NONE},
  turn = "x",
  status = "playing"
}
local function cell_at(pos)
  return board.cells[pos]
end
local function check_end()
  local lines = {{1, 2, 3}, {4, 5, 6}, {7, 8, 9}, {1, 4, 7}, {2, 5, 8}, {3, 6, 9}, {1, 5, 9}, {3, 5, 7}}
  for _, line in ipairs(lines) do
    local a = cell_at((line[1]))
    local b = cell_at((line[2]))
    local c = cell_at((line[3]))
    if not (_is_none(a)) then
      if a == b and b == c then
        board.status = (a == "x" and "x-wins" or "o-wins")
        return nil
      end
    end
  end
  local state = {
    full = true
  }
  for _, c in ipairs(board.cells) do
    if _is_none(c) then
      state.full = false
    end
  end
  if state.full then
    board.status = "draw"
    return board.status
  end
end
local function place(pos, mark)
  if not (board.status == "playing") then
    return false
  end
  if not (_is_none(cell_at(pos))) then
    return false
  end
  local new_cells = (function() local r={}; for i,v in ipairs(board.cells) do r[i]=v end; return r end)()
  table.remove(new_cells, pos)
  table.insert(new_cells, pos, mark)
  board.cells = new_cells
  check_end()
  board.turn = (board.turn == "x" and "o" or "x")
  return true
end
local function reset()
  board.cells = {_NONE, _NONE, _NONE, _NONE, _NONE, _NONE, _NONE, _NONE, _NONE}
  board.turn = "x"
  board.status = "playing"
  return board.status
end
local function find_winning(mark)
  local lines = {{1, 2, 3}, {4, 5, 6}, {7, 8, 9}, {1, 4, 7}, {2, 5, 8}, {3, 6, 9}, {1, 5, 9}, {3, 5, 7}}
  local state = {
    result = nil
  }
  for _, line in ipairs(lines) do
    local a = line[1]
    local b = line[2]
    local c = line[3]
    local va = cell_at(a)
    local vb = cell_at(b)
    local vc = cell_at(c)
    if va == mark and vb == mark and _is_none(vc) then
      state.result = c
    end
    if va == mark and _is_none((vb and vc == mark)) then
      state.result = b
    end
    if _is_none((va and vb == mark and vc == mark)) then
      state.result = a
    end
  end
  return state.result
end
local function ai_move()
  local w = find_winning("o")
  if not (_is_none(w)) then
    return w
  end
  local b = find_winning("x")
  if not (_is_none(b)) then
    return b
  end
  if _is_none(cell_at(5)) then
    return 5
  end
  local state = {
    choice = nil
  }
  for _, c in ipairs({1, 3, 7, 9}) do
    if _is_none(cell_at(c)) then
      state.choice = c
    end
  end
  if not (_is_none(state.choice)) then
    return state.choice
  end
  for i = 1, 9 do
    if _is_none(cell_at(i)) then
      return i
    end
  end
end
local function pos_to_xy(pos)
  local row = math.floor((pos - 1) / 3)
  local col = (pos - 1) % 3
  local x = offset + padding + col * cell_size
  local y = offset + padding + row * cell_size
  return {x, y}
end
local function xy_to_pos(mx, my)
  local col = math.floor((mx - offset - padding) / cell_size)
  local row = math.floor((my - offset - padding) / cell_size)
  if col >= 0 and col < 3 and row >= 0 and row < 3 then
    return row * 3 + col + 1
  end
end
love.draw = function()
  love.graphics.clear((bg[1]), (bg[2]), (bg[3]))
  love.graphics.setColor((grid[1]), (grid[2]), (grid[3]))
  love.graphics.setLineWidth(2)
  for i = 1, 2 do
    local x = offset + padding + i * cell_size
    local y = offset + padding + i * cell_size
    love.graphics.line(x, (offset + padding), x, (offset + padding + cell_size * 3))
    love.graphics.line((offset + padding), y, (offset + padding + cell_size * 3), y)
  end
  for pos = 1, 9 do
    local cell = cell_at(pos)
    if not (_is_none(cell)) then
      local coords = pos_to_xy(pos)
      local cx = (coords[1]) + cell_size / 2
      local cy = (coords[2]) + cell_size / 2
      if cell == "x" then
        love.graphics.setColor((x_clr[1]), (x_clr[2]), (x_clr[3]))
        love.graphics.setLineWidth(line_width)
        local m = cell_size / 4
        local px = coords[1]
        local py = coords[2]
        love.graphics.line((px + m), (py + m), (px + cell_size - m), (py + cell_size - m))
        love.graphics.line((px + cell_size - m), (py + m), (px + m), (py + cell_size - m))
      else
        love.graphics.setColor((o_clr[1]), (o_clr[2]), (o_clr[3]))
        love.graphics.setLineWidth(line_width)
        love.graphics.circle("line", cx, cy, (cell_size / 3))
      end
    end
  end
  love.graphics.setColor((txt[1]), (txt[2]), (txt[3]))
  if board.status == "playing" then
    local msg = (board.turn == "x" and "Your turn (click a cell)" or "AI thinking...")
    love.graphics.printf(msg, 0, 475, 480, "center")
  else
    if board.status == "x-wins" then
      love.graphics.setColor((win[1]), (win[2]), (win[3]))
      love.graphics.printf("You win! Click to restart.", 0, 475, 480, "center")
    else
      if board.status == "o-wins" then
        love.graphics.setColor((x_clr[1]), (x_clr[2]), (x_clr[3]))
        love.graphics.printf("AI wins! Click to restart.", 0, 475, 480, "center")
      else
        love.graphics.setColor((drw[1]), (drw[2]), (drw[3]))
        love.graphics.printf("Draw! Click to restart.", 0, 475, 480, "center")
      end
    end
  end
end
love.mousepressed = function(mx, my, button)
  if not (button == 1) then
    return nil
  end
  if not (board.status == "playing") then
    reset()
    return nil
  end
  if not (board.turn == "x") then
    return nil
  end
  local pos = xy_to_pos(mx, my)
  if _is_none(pos) then
    return nil
  end
  if not (_is_none(board.cells[pos])) then
    return nil
  end
  local placed = place(pos, "x")
  if _is_none(placed) then
    return nil
  end
  if board.status == "playing" then
    local ai_pos = ai_move()
    if not (_is_none(ai_pos)) then
      place(ai_pos, "o")
    end
  end
end
