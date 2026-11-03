local Services = script.Parent.Services

-- importar modulos
local PlayerService = require(Services.PlayerService)
local DataService = require(Services.DataService)
local GameplayService =  require(Services.GameplayService)

-- inicializar
PlayerService:Init()
DataService:Init()
GameplayService:Init()

print("Servidor inicializado")