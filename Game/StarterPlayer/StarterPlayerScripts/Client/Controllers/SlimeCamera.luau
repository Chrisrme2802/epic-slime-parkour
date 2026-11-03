local SlimeCamera = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local SlimeConfig = require(Config:WaitForChild("SlimeConfig"))

local MIN_PITCH = -1.3 -- mirando hacia abajo (camara por encima)
local MAX_PITCH = 0.5  -- mirando hacia arriba

local camUp = Vector3.yAxis
local camForward = -Vector3.zAxis
local pitch = math.rad(-15)

local getUp: (() -> Vector3)?
local getSubject: (() -> BasePart?)?

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function projectOnPlane(v: Vector3, normal: Vector3): Vector3
	return v - v:Dot(normal) * normal
end

function SlimeCamera:Update(dt: number)
	local camera = workspace.CurrentCamera
	local subject = getSubject and getSubject()
	if not camera or not subject or not subject.Parent or not getUp then return end

	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	-- 1) rotar el "arriba" de la camara hacia el de la superficie (slerp),
	--    arrastrando la direccion de vista con la misma rotacion para no perder orientacion
	local desiredUp = getUp()
	local axis = camUp:Cross(desiredUp)
	local angle = math.atan2(axis.Magnitude, camUp:Dot(desiredUp))
	if angle > 1e-4 then
		if axis.Magnitude < 1e-4 then
			axis = camForward:Cross(camUp) -- vectores opuestos: eje arbitrario valido
		end
		local alpha = 1 - math.exp(-SlimeConfig.CameraUpSmooth * dt)
		local rot = CFrame.fromAxisAngle(axis.Unit, angle * alpha)
		camUp = rot:VectorToWorldSpace(camUp).Unit
		camForward = rot:VectorToWorldSpace(camForward)
	end

	-- 2) mouse: yaw alrededor del up, pitch limitado
	local delta = UserInputService:GetMouseDelta()
	local sens = SlimeConfig.CameraSensitivity
	camForward = CFrame.fromAxisAngle(camUp, -delta.X * sens):VectorToWorldSpace(camForward)
	pitch = math.clamp(pitch - delta.Y * sens, MIN_PITCH, MAX_PITCH)

	-- 3) re-ortogonalizar
	camForward = projectOnPlane(camForward, camUp)
	if camForward.Magnitude < 1e-3 then
		camForward = projectOnPlane(camera.CFrame.LookVector, camUp)
		if camForward.Magnitude < 1e-3 then
			camForward = camUp:Cross(Vector3.xAxis)
		end
	end
	camForward = camForward.Unit

	-- 4) posicion de la camara
	local lookDir = camForward * math.cos(pitch) + camUp * math.sin(pitch)
	local focus = subject.Position + camUp * SlimeConfig.CameraHeight
	local dist = SlimeConfig.CameraDistance

	local character = subject.Parent
	if character then
		rayParams.FilterDescendantsInstances = { character }
	end
	local hit = workspace:Raycast(focus, -lookDir * dist, rayParams)
	if hit then
		dist = math.max(1, hit.Distance - 0.5)
	end

	local camPos = focus - lookDir * dist
	camera.CFrame = CFrame.lookAt(camPos, focus, camUp)
	camera.Focus = CFrame.new(focus)
end

function SlimeCamera:Init(upGetter: () -> Vector3, subjectGetter: () -> BasePart?)
	getUp = upGetter
	getSubject = subjectGetter

	UserInputService.MouseIconEnabled = false
	RunService:BindToRenderStep("SlimeCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:Update(dt)
	end)
end

return SlimeCamera