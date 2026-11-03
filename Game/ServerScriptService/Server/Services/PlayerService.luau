local PlayerService = {} 

-- roblox services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- config
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local SlimeConfig = require(Config:WaitForChild("SlimeConfig"))

-- network
local Network = ReplicatedStorage:WaitForChild("Network")
local RemoteEvents = ReplicatedStorage:WaitForChild("RemoteEvents")

function PlayerService:OnCharacterAdded(player, character)
    print("Personaje instanciado para: ", player.name)

    -- propiedades de humanoid coincidir con SlimeConfig
    local humanoid = character:WaitForChild("Humanoid")
    if humanoid then
        humanoid.WalkSpeed = SlimeConfig.WalkSpeed
        humanoid.JumpPower = SlimeConfig.JumpPower
    end
end

function PlayerService:OnPlayerAdded(player)
    print("Jugador: ", player.name, "| User ID: ", player.UserId)

    -- instanciar character
    player.CharacterAdded:Connect(function(character)
        self:OnCharacterAdded(player, character)
    end)

    -- si character ya existe
    if player.Character then
        self:OnCharacterAdded(player, player.Character)
    end
end

function PlayerService:OnPlayerRemoving(player)
    print("Jugador desconectado: ", player.name)
end

function PlayerService:Init()
    print("PlayerService inicializado")

    -- conexiones y desconexiones
    Players.PlayerAdded:Connect(function(player)
        self:OnPlayerAdded(player)
    end)
    Players.PlayerRemoving:Connect(function(player)
        self:OnPlayerRemoving(player)
    end)

    -- player siempre lo inyecta roblox 
    RemoteEvents.SetClimbingState.OnServerEvent:Connect(function(player, isClimbing, surfaceNormal)
        print("Player: ", player.Name, " cambio estado a: ",isClimbing)
    end)
end

return PlayerService