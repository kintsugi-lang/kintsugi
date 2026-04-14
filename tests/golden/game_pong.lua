local is_paused = false
local player_score = 0
local cpu_score = 0
local player = {
  x = 20,
  y = 260,
  w = 12,
  h = 80,
  cr = 0.9,
  cg = 0.9,
  cb = 1
}
local cpu = {
  x = 768,
  y = 260,
  w = 12,
  h = 80,
  cr = 0.9,
  cg = 0.9,
  cb = 1
}
local ball = {
  x = 396,
  y = 296,
  w = 8,
  h = 8,
  cr = 1,
  cg = 0.8,
  cb = 0.2,
  dx = 1,
  dy = 0,
  speed = 350
}
love.load = function()
end
love.update = function(dt)
  if not (is_paused) then
    if love.keyboard.isDown("w") then
      player.y = player.y - (420 * dt)
    end
    if love.keyboard.isDown("s") then
      player.y = player.y + (420 * dt)
    end
  end
  if not (is_paused) then
    cpu.y = ball.y - 40
  end
  if not (is_paused) then
    ball.x = ball.x + (ball.dx * ball.speed * dt)
    ball.y = ball.y + (ball.dy * ball.speed * dt)
    if ball.y < 0 then
      ball.y = 0
      ball.dy = -(ball.dy)
    end
    if ball.y > (600 - 8) then
      ball.y = 600 - 8
      ball.dy = -(ball.dy)
    end
    if ball.x < 0 then
      cpu_score = cpu_score + 1
      ball.x = 396
      ball.y = 296
      ball.dx = 1
      ball.dy = 0
      ball.speed = 350
    end
    if ball.x > 800 then
      player_score = player_score + 1
      ball.x = 396
      ball.y = 296
      ball.dx = -1
      ball.dy = 0
      ball.speed = 350
    end
  end
  if (ball.x < (player.x + player.w) and player.x < (ball.x + ball.w) and ball.y < (player.y + player.h) and player.y < (ball.y + ball.h)) then
    ball.dx = -(ball.dx)
    ball.dy = (ball.y - player.y) / 40
    ball.speed = ball.speed + 20
  end
  if (ball.x < (cpu.x + cpu.w) and cpu.x < (ball.x + ball.w) and ball.y < (cpu.y + cpu.h) and cpu.y < (ball.y + ball.h)) then
    ball.dx = -(ball.dx)
    ball.dy = (ball.y - cpu.y) / 40
    ball.speed = ball.speed + 20
  end
end
love.draw = function()
  love.graphics.setColor(player.cr, player.cg, player.cb, 1)
  love.graphics.rectangle("fill", player.x, player.y, player.w, player.h)
  love.graphics.setColor(cpu.cr, cpu.cg, cpu.cb, 1)
  love.graphics.rectangle("fill", cpu.x, cpu.y, cpu.w, cpu.h)
  love.graphics.setColor(ball.cr, ball.cg, ball.cb, 1)
  love.graphics.rectangle("fill", ball.x, ball.y, ball.w, ball.h)
  love.graphics.print(player_score .. "   " .. cpu_score, 380, 20)
end
love.keypressed = function(key)
  if key == "space" then
    is_paused = not (is_paused)
  elseif key == "escape" then
    love.event.quit()
  else
  end
end
