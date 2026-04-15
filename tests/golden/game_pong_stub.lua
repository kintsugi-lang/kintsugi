local player = {
  x = 20,
  y = 260,
  w = 12,
  h = 80,
  cr = 0.9,
  cg = 0.9,
  cb = 1,
  is_alive = true
}
local cpu = {
  x = 768,
  y = 260,
  w = 12,
  h = 80,
  cr = 0.9,
  cg = 0.9,
  cb = 1,
  is_alive = true
}
local ball = {
  x = 396,
  y = 296,
  w = 8,
  h = 8,
  cr = 1,
  cg = 0.8,
  cb = 0.2,
  is_alive = true
}
love.load = function()
end
love.update = function(dt)
end
love.draw = function()
  if player.is_alive then
    love.graphics.setColor(player.cr, player.cg, player.cb, 1)
    love.graphics.rectangle("fill", player.x, player.y, player.w, player.h)
  end
  if cpu.is_alive then
    love.graphics.setColor(cpu.cr, cpu.cg, cpu.cb, 1)
    love.graphics.rectangle("fill", cpu.x, cpu.y, cpu.w, cpu.h)
  end
  if ball.is_alive then
    love.graphics.setColor(ball.cr, ball.cg, ball.cb, 1)
    love.graphics.rectangle("fill", ball.x, ball.y, ball.w, ball.h)
  end
end
