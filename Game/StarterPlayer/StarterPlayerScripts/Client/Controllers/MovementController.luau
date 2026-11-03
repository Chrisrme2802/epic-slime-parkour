local MovementController = {}

-- servicios roblox
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

-- config
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local SlimeConfig = require(Config:WaitForChild("SlimeConfig"))

-- network
local Network = ReplicatedStorage:WaitForChild("Network")
local RemoteEvents = ReplicatedStorage:WaitForChild("RemoteEvents")

-- referencias locales
local localPlayer = Players.LocalPlayer
local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
local humanoid = character:WaitForChild("Humanoid")
local isStuckToSurface = false

function MovementController:Init()
    print("Movement controller para: ", localPlayer.Name)

    -- base
    if humanoid then
        humanoid.WalkSpeed = SlimeConfig.WalkSpeed
    end

    -- respawn
    localPlayer.CharacterAdded:Connect(function(newCharacter)
        character = newCharacter
        humanoidRootPart = character:WaitForChild("HumanoidRootPart")
        humanoid = character:WaitForChild("Humanoid")

        humanoid.WalkSpeed = SlimeConfig.WalkSpeed
    end)

    -- evento de actualizacion
    RunService.Heartbeat:Connect(function(deltaTime)
        self:CheckSurfaces()
    end)
end

function MovementController:CheckSurfaces()
    if not character or not humanoidRootPart then return end

    -- param raycast
    local raycastParams = RaycastParams.new()
    local filterObjects = {character}
    raycastParams.FilterDescendantsInstances = filterObjects
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude

    -- directions
    local directions = {
        Vector3.new(0,0,-1), --frente
        Vector3.new(0,0,1),  --atras
        Vector3.new(-1,0,0), --izquierda
        Vector3.new(1,0,0),  --derecha
        Vector3.new(0,1,0),  --arriba
        Vector3.new(0,-1,0), --abajo
    }

    local isTouchingSurface = false
    local surfaceNormal = Vector3.zero
 
    for _, dir in ipairs(directions) do
        -- convert direction character
        local worldDirection = humanoidRootPart.CFrame:VectorToWorldSpace(dir) * SlimeConfig.RayDistance
        local result = workspace:Raycast(humanoidRootPart.Position, worldDirection, raycastParams)

        if result then
            -- surface
            isTouchingSurface = true
            surfaceNormal = result.Normal
            break
        end
    end
    
    if isTouchingSurface ~= isStuckToSurface then
        isStuckToSurface = isTouchingSurface
        RemoteEvents.SetClimbingState:FireServer(isStuckToSurface, surfaceNormal)
    end
end

return MovementController