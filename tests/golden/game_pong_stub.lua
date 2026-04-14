local SCREEN_W <const> = 800
local SCREEN_H <const> = 600
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
  cb = 0.2
}
love.load = function()
end
love.update = function(dt)
end
love.draw = function()
  love.graphics.setColor(player.cr, player.cg, player.cb, 1)
  love.graphics.rectangle("fill", player.x, player.y, player.w, player.h)
  love.graphics.setColor(cpu.cr, cpu.cg, cpu.cb, 1)
  love.graphics.rectangle("fill", cpu.x, cpu.y, cpu.w, cpu.h)
  love.graphics.setColor(ball.cr, ball.cg, ball.cb, 1)
  love.graphics.rectangle("fill", ball.x, ball.y, ball.w, ball.h)
end
love.keypressed = function(key)
end
