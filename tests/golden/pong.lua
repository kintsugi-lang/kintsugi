-- Kintsugi runtime support
math.randomseed(os.time())

local lg = love.graphics
local le = love.event
local lw = love.window
local lk = love.keyboard
local SCREEN_W = 800
local SCREEN_H = 600
local PADDLE_W = 12
local PADDLE_H = 80
local PADDLE_SPEED = 400
local BALL_SIZE = 8
local BALL_SPEED = 300
local game = {
  paused = true,
  font = nil
}
local player = {
  x = 20,
  y = 260,
  score = 0,
  speed = PADDLE_SPEED
}
local cpu = {
  x = 768,
  y = 260,
  score = 0,
  speed = PADDLE_SPEED
}
local ball = {
  x = 396,
  y = 296,
  dx = 1,
  dy = 1,
  speed = BALL_SPEED
}
local function reset_ball()
  ball.x = 396
  ball.y = 296
  if ball.dx > 0 then
    ball.dx = -1
  else
    ball.dx = 1
  end
  if math.random(2) == 1 then
    ball.dy = 1
  else
    ball.dy = -1
  end
  ball.speed = BALL_SPEED
  game.paused = true
  return game.paused
end
love.load = function()
  lw.setMode(SCREEN_W, SCREEN_H)
  lw.setTitle("Kintsugi Pong")
  game.font = lg.newFont(24)
end
love.keypressed = function(key)
  if key == "space" then
    game.paused = not (game.paused)
  elseif key == "r" then
    player.score = 0
    cpu.score = 0
    reset_ball()
  elseif key == "escape" then
    le.quit()
  end
end
love.update = function(dt)
  if not (game.paused) then
    if lk.isDown("w") then
      player.y = player.y - (player.speed * dt)
    end
    if lk.isDown("s") then
      player.y = player.y + (player.speed * dt)
    end
    if player.y < 0 then
      player.y = 0
    end
    if player.y > (SCREEN_H - PADDLE_H) then
      player.y = SCREEN_H - PADDLE_H
    end
    local cpu_center = cpu.y + (PADDLE_H / 2)
    if cpu_center < (ball.y - 20) then
      cpu.y = cpu.y + (cpu.speed * dt * 0.7)
    end
    if cpu_center > (ball.y + 20) then
      cpu.y = cpu.y - (cpu.speed * dt * 0.7)
    end
    if cpu.y < 0 then
      cpu.y = 0
    end
    if cpu.y > (SCREEN_H - PADDLE_H) then
      cpu.y = SCREEN_H - PADDLE_H
    end
    ball.x = ball.x + (ball.dx * ball.speed * dt)
    ball.y = ball.y + (ball.dy * ball.speed * dt)
    if ball.y < 0 then
      ball.y = 0
      ball.dy = -(ball.dy)
    end
    if ball.y > (SCREEN_H - BALL_SIZE) then
      ball.y = SCREEN_H - BALL_SIZE
      ball.dy = -(ball.dy)
    end
    if (ball.dx < 0 and ball.x < (player.x + PADDLE_W) and ball.y > (player.y - BALL_SIZE) and ball.y < (player.y + PADDLE_H)) then
      ball.x = player.x + PADDLE_W
      ball.dx = -(ball.dx)
      ball.speed = ball.speed + 20
    end
    if (ball.dx > 0 and ball.x > (cpu.x - BALL_SIZE) and ball.y > (cpu.y - BALL_SIZE) and ball.y < (cpu.y + PADDLE_H)) then
      ball.x = cpu.x - BALL_SIZE
      ball.dx = -(ball.dx)
      ball.speed = ball.speed + 20
    end
    if ball.x < 0 then
      cpu.score = cpu.score + 1
      reset_ball()
    end
    if ball.x > SCREEN_W then
      player.score = player.score + 1
      reset_ball()
    end
  end
end
love.draw = function()
  lg.setColor(0.3, 0.3, 0.4, 1)
  lg.rectangle("fill", 398, 0, 4, SCREEN_H)
  lg.setColor(0.9, 0.9, 1, 1)
  lg.rectangle("fill", player.x, player.y, PADDLE_W, PADDLE_H)
  lg.rectangle("fill", cpu.x, cpu.y, PADDLE_W, PADDLE_H)
  lg.setColor(1, 0.8, 0.2, 1)
  lg.circle("fill", ball.x, ball.y, BALL_SIZE)
  lg.setFont(game.font)
  lg.setColor(1, 1, 1, 1)
  lg.print(tostring(player.score), 340, 20)
  lg.print(tostring(cpu.score), 440, 20)
  if game.paused then
    lg.setColor(1, 1, 1, 0.6)
    lg.print("SPACE to start  |  W/S to move  |  R to reset", 200, 560)
  end
end
