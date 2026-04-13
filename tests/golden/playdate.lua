import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/timer"
local gfx = playdate.graphics
local playerSprite = nil
local function myGameSetUp()
  local playerImage = gfx.image.new("Images/playerImage")
  assert(playerImage)
  playerSprite = gfx.sprite.new(playerImage)
  playerSprite:moveTo(200, 120):add()
  local backgroundImage = gfx.image.new("Images/background")
  assert(backgroundImage)
  return gfx.sprite.setBackgroundDrawingCallback(function(x, y, width, height)
    return backgroundImage:draw(0, 0)
  end)
end
myGameSetUp()
playdate.update = function()
  if playdate.buttonIsPressed(playdate.kButtonUp) then
    playerSprite:moveBy(0, -2)
  end
  if playdate.buttonIsPressed(playdate.kButtonRight) then
    playerSprite:moveBy(2, 0)
  end
  if playdate.buttonIsPressed(playdate.kButtonDown) then
    playerSprite:moveBy(0, 2)
  end
  if playdate.buttonIsPressed(playdate.kButtonLeft) then
    playerSprite:moveBy(-2, 0)
  end
  gfx.sprite.update()
  playdate.timer.updateTimers()
end
