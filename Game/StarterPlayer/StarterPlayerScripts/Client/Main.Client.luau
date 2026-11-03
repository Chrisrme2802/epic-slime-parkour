print("Intentando iniciar cliente")
local Controllers = script.Parent.Controllers
local MovementController = require(Controllers.MovementController)
local SlimeCamera = require(Controllers.SlimeCamera)

MovementController:Init()
SlimeCamera:Init(
    function() return MovementController:GetUp() end,
	function() return MovementController:GetSubject() end
)
print("Cliente iniciado")