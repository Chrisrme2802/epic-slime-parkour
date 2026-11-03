local RemoteEvents = {}

-- servicios de roblox
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- crear / obtener remote event
local function getOrCreateRemoteEvent(eventName: string): RemoteEvent
    local event = ReplicatedStorage:FindFirstChild(eventName)
    if not event then
        event = Instance.new("RemoteEvent")
        event.Name = eventName
        event.Parent = ReplicatedStorage
    end
    return event :: RemoteEvent
end

RemoteEvents.SetClimbingState = getOrCreateRemoteEvent("SetClimbingState")

return RemoteEvents