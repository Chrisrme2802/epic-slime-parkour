local DataService = {}

-- servicios de roblox
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

-- base de datos
local SlimeDataStore = DataStoreService:GetDataStore("SlimeParkour_v1")

-- cache
local sessionData = {}

-- dto jugador
local DEFAULT_DATA = {
    CurrentLevel = 1,
    Coins = 0,
    UnlockedSlimes = {"DefaultGreen"},
    EquippedSlime = "DefaultGreen",
}

local function copyTable(originalTable)
    local copy = {}
    for key, value in pairs(originalTable) do
        if type(value) == "table" then
            copy[key] = copyTable(value)
        else 
            copy[key] = value
        end
    end
    return copy
end

function DataService:LoadData(player: Player)
    local dataKey = "Player_" .. player.UserId

    local success, result = pcall(function()
        return SlimeDataStore:GetAsync(dataKey)
    end)

    if success then
        if result then
            -- ya tenia
            sessionData[player.UserId] = result
            print("Datos con exito para: ", player.Name)
        else
            -- nuevo
            sessionData[player.UserId] = copyTable(DEFAULT_DATA)
            print("Jugador nuevo: ", player.Name)
        end
    else 
        warn("Error al cargar datos de " .. player.Name .. ":", result)
        -- datos por defecto
        sessionData[player.UserId] = copyTable(DEFAULT_DATA)
    end
end

function DataService:SaveData(player: Player)
    local userId = player.UserId
    local playerCache = sessionData[userId]

    if not playerCache then return end

    local dataKey = "Player_" .. userId

    -- try
    local success, result = pcall(function()
        SlimeDataStore:SetAsync(dataKey, playerCache)
    end)

    if success then
        print("Datos guardados para: ", player.Name)
    else
        warn("Error al guardar datos para " .. player.Name .. ":", result)
    end

    -- limpiar
    sessionData[userId] = nil
end

function DataService:GetData(player: Player)
    return sessionData[player.UserId]
end

function DataService:SetCheckpoint(player: Player, levelNumber: number)
    local data = sessionData[player.UserId]
    if data then
        data.CurrentLevel = levelNumber
        print("Nivel: ", levelNumber, "para player: ", player.Name)
    end
end

function DataService:Init()
    print("DataService inicializado")

    -- cargar datos
    Players.PlayerAdded:Connect(function(player)
        self:LoadData(player)
    end)

    -- guardar al salir
    Players.PlayerRemoving:Connect(function(player)
        self:SaveData(player)
    end)

    -- guardar si cierra
    game:BindToClose(function()
        for _, player in ipairs(Players:GetPlayers()) do
            self:SaveData(player)
        end
    end)
end

return DataService