local GameplayService = {}

-- servicios de roblox
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStroage = game:GetService("ReplicatedStorage")

-- services
local Services = script.Parent
local DataService = require(Services.DataService)

-- locales
local checkpoints = {}

function GameplayService:RegisterCheckpoints()
    -- carpeta de checkpoints en workspace
    local checkpointsFolder = Workspace:FindFirstChild("Checkpoints")
    if not checkpointsFolder then
        warn("No se encontro la carpeta")
        return
    end

    for _, part in ipairs(checkpointsFolder:GetChildren()) do
        if part:IsA("BasePart") then
            local levelNumber = tonumber(part.Name)
            if levelNumber then
                checkpoints[levelNumber] = part

                -- colisiones del bloque
                part.Touched:Connect(function(hit)
                    self:OnCheckPointTouched(hit, levelNumber)
                end)
            end
        end
    end
    print("Checkpoints registrados")
end

function GameplayService:OnCheckPointTouched(hit: BasePart, levelNumber: number)
    local character = hit.Parent
    local player = Players:GetPlayerFromCharacter(character)
    if not player then return end

    local playerCache = DataService:GetData(player)
    if not playerCache then return end

    -- solo si es superior
    if levelNumber > playerCache.CurrentLevel then
        DataService:SetCheckpoint(player, levelNumber)
    end
end

function GameplayService:TeleportToCurrentCheckpoint(player: Player, character: Model)
    local playerCache = DataService:GetData(player)
    local currentLevel = playerCache and playerCache.CurrentLevel or 1

    local targetCheckpoint = checkpoints[currentLevel]

    if targetCheckpoint then
        local humanoidRootPart = character:WaitForChild("HumanoidRootPart",5)
        if humanoidRootPart then
            -- colocar arriba
            humanoidRootPart.CFrame = targetCheckpoint.CFrame + Vector3.new(0,3,0)
        end
    end
end

function GameplayService:Init()
    print("GameplayService inicializado")

    -- registrar checkpoint en carpeta
    self:RegisterCheckpoints()

    -- mover jugador a checkpoint
    Players.PlayerAdded:Connect(function(player)
        player.CharacterAdded:Connect(function(character)
            task.wait(0.1) -- pausa para cargar modelo
            self:TeleportToCurrentCheckpoint(player, character)
        end)
    end)
end

return GameplayService