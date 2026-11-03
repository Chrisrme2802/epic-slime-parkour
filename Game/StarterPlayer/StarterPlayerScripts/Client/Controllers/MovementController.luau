local MovementController = {}

-- servicios
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- config
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local SlimeConfig = require(Config:WaitForChild("SlimeConfig"))

-- network
local Network = ReplicatedStorage:WaitForChild("Network")
local RemoteEvents = require(Network:WaitForChild("RemoteEvents"))

-- input (teclado, gamepad y tactil)
local localPlayer = Players.LocalPlayer
local controls: any = nil

-- constantes de algoritmo
local NORMAL_CHANGE_DOT = 0.98  -- dot menor a esto = superficie distinta (para red)
local SURFACE_BLEND_DOT = 0.7   -- por encima: pendiente/curva suave. Por debajo: cambio brusco de cara
local JUMP_BUFFER = 0.15        -- segundos que se recuerda un salto pedido antes de tocar suelo
local COYOTE_TIME = 0.12        -- segundos de gracia para saltar tras dejar la superficie

-- referencias
local character: Model?
local humanoid: Humanoid?
local humanoidRootPart: BasePart?

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local attachment: Attachment?
local alignOrientation: AlignOrientation?
local linearVelocity: LinearVelocity?

local hoverHeight = 3
local stickDistance = 4.5

-- estado
local targetUp = Vector3.yAxis
local facing = -Vector3.zAxis
local tangentVelocity = Vector3.zero
local upSpeed = 0
local grounded = false
local coyoteAvailable = false
local lastGroundedTime = 0
local jumpRequestedAt = -math.huge

local lastSentNormal = Vector3.yAxis
local lastSentStuck = false
local lastSentTime = 0

task.spawn(function()
	local playerScripts = localPlayer:WaitForChild("PlayerScripts")
	local playerModule = playerScripts:WaitForChild("PlayerModule", 10)
	if playerModule then
		controls = (require :: any)(playerModule):GetControls()
	else
		warn("PlayerModule no encontrado, usando WASD de respaldo")
	end
end)

local function getRawInput(): Vector3
	if controls then
		return controls:GetMoveVector()
	end
	-- respaldo: solo teclado
	local x = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
	local z = (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
	return Vector3.new(x, 0, z)
end

----------------------------------------------------------------------
-- utilidades
----------------------------------------------------------------------

local function projectOnPlane(v: Vector3, normal: Vector3): Vector3
	return v - v:Dot(normal) * normal
end

local function anyTangent(up: Vector3): Vector3
	local ref = math.abs(up.X) < 0.9 and Vector3.xAxis or Vector3.zAxis
	return ref:Cross(up).Unit
end

local function resetState()
	targetUp = Vector3.yAxis
	facing = -Vector3.zAxis
	tangentVelocity = Vector3.zero
	upSpeed = 0
	grounded = false
	coyoteAvailable = false
	lastGroundedTime = os.clock()
	jumpRequestedAt = -math.huge
	lastSentNormal = Vector3.yAxis
	lastSentStuck = false
end

local function createPhysicsObjects(root: BasePart)
	if attachment then attachment:Destroy() end
	if alignOrientation then alignOrientation:Destroy() end
	if linearVelocity then linearVelocity:Destroy() end

	local newAttachment = Instance.new("Attachment")
	newAttachment.Name = "SlimeAttachment"
	newAttachment.Parent = root
	attachment = newAttachment

	local align = Instance.new("AlignOrientation")
	align.Name = "SlimeAlignOrientation"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = newAttachment
	align.RigidityEnabled = false
	align.Responsiveness = 25
	align.MaxTorque = math.huge
	align.Parent = root
	alignOrientation = align

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "SlimeLinearVelocity"
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.Attachment0 = newAttachment
	velocity.MaxForce = root.AssemblyMass * SlimeConfig.MaxAccel
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = root
	linearVelocity = velocity
end

local function bindCharacter(newCharacter: Model)
	character = newCharacter
	local hum = newCharacter:WaitForChild("Humanoid") :: Humanoid
	local root = newCharacter:WaitForChild("HumanoidRootPart") :: BasePart
	humanoid = hum
	humanoidRootPart = root

	rayParams.FilterDescendantsInstances = { newCharacter }

	hoverHeight = SlimeConfig.HoverHeight or (hum.HipHeight + root.Size.Y / 2)
	stickDistance = hoverHeight + SlimeConfig.StickMargin

	-- el Humanoid ya no maneja el movimiento: lo hacemos nosotros
	hum.AutoRotate = false
	hum.PlatformStand = true

	createPhysicsObjects(root)
	resetState()
end

----------------------------------------------------------------------
-- input -> direccion tangente a la superficie
----------------------------------------------------------------------

local function getMoveDirection(up: Vector3): Vector3
	local input = getRawInput()
	if input.Magnitude < 0.01 then return Vector3.zero end

	local camera = workspace.CurrentCamera
	if not camera then return Vector3.zero end
	local camCF = camera.CFrame

	local forward = projectOnPlane(camCF.LookVector, up)
	if forward.Magnitude < 0.3 then
		forward = projectOnPlane(camCF.UpVector, up) -- camara mirando casi de frente/arriba abajo
	end
	if forward.Magnitude < 0.001 then return Vector3.zero end
	forward = forward.Unit
	local right = forward:Cross(up)

	local dir = right * input.X + forward * -input.Z
	if dir.Magnitude > 1 then dir = dir.Unit end
	return dir
end

----------------------------------------------------------------------
-- red
----------------------------------------------------------------------

local function syncServer(now: number)
	local stuck = targetUp.Y < SlimeConfig.FloorYThreshold
	local changed = stuck ~= lastSentStuck or lastSentNormal:Dot(targetUp) < NORMAL_CHANGE_DOT
	if changed and (now - lastSentTime) >= SlimeConfig.NetworkInterval then
		lastSentStuck = stuck
		lastSentNormal = targetUp
		lastSentTime = now
		RemoteEvents.SetClimbingState:FireServer(stuck, targetUp)
	end
end

----------------------------------------------------------------------
-- paso de simulacion
----------------------------------------------------------------------

local function step(dt: number)
	local root = humanoidRootPart
	local vel = linearVelocity
	local align = alignOrientation
	if not root or not root.Parent or not vel or not align then return end
	if not humanoid or humanoid.Health <= 0 then return end

	local now = os.clock()
	local pos = root.Position
	local up = targetUp
	local wasGrounded = grounded

	local move = getMoveDirection(up)
	local moveDir = move.Magnitude > 0.01 and move.Unit or nil

	-- 1) salto (con buffer y coyote time)
	if (now - jumpRequestedAt) < JUMP_BUFFER and (grounded or (coyoteAvailable and (now - lastGroundedTime) < COYOTE_TIME)) then
		upSpeed = SlimeConfig.JumpPower
		grounded = false
		wasGrounded = false
		coyoteAvailable = false
		jumpRequestedAt = -math.huge
	end

	-- 2) esquina concava: pared por delante -> esa pared pasa a ser el suelo
	local transitioned = false
	if wasGrounded and moveDir then
		local wall = workspace:Raycast(pos, moveDir * SlimeConfig.RayDistance, rayParams)
		if wall and wall.Normal:Dot(up) < SURFACE_BLEND_DOT then
			targetUp = wall.Normal
			transitioned = true
		end
	end

	-- 3) suelo bajo los pies (solo si no vamos subiendo por un salto)
	local groundHit: RaycastResult? = nil
	if not transitioned and upSpeed <= 0 then
		groundHit = workspace:Raycast(pos, -up * stickDistance, rayParams)
	end

	if groundHit then
		local n = groundHit.Normal
		if n:Dot(up) > SURFACE_BLEND_DOT then
			-- pendiente suave o superficie curva: seguir la normal suavemente
			local blended = up:Lerp(n, 1 - math.exp(-SlimeConfig.SurfaceBlendRate * dt))
			targetUp = blended.Unit
		else
			-- cambio brusco de cara justo bajo nosotros
			targetUp = n
			transitioned = true
		end
		grounded = true
	elseif transitioned then
		grounded = true
	elseif wasGrounded and upSpeed <= 0 and moveDir then
		-- 4) arista convexa: ya no hay suelo bajo el centro. Buscar la cara lateral
		-- lanzando un rayo hacia atras desde por debajo del plano de la superficie.
		local origin = pos - up * (hoverHeight + 1)
		local wrap = workspace:Raycast(origin, -moveDir * SlimeConfig.EdgeProbeDistance, rayParams)
		if wrap and wrap.Normal:Dot(moveDir) > 0.5 then
			targetUp = wrap.Normal
			transitioned = true
			grounded = true
		else
			grounded = false
		end
	else
		grounded = false
	end

	if grounded then
		coyoteAvailable = true
		lastGroundedTime = now
		upSpeed = 0
	end

	up = targetUp
	if transitioned then
		move = projectOnPlane(move, up)
	end

	-- 5) gravedad propia en el aire
	if not grounded then
		upSpeed = math.max(upSpeed - SlimeConfig.Gravity * dt, -SlimeConfig.MaxFallSpeed)
		if (now - lastGroundedTime) > SlimeConfig.AirResetTime then
			-- llevamos mucho en el aire: volver poco a poco a la gravedad normal
			local l = targetUp:Lerp(Vector3.yAxis, 1 - math.exp(-2 * dt))
			if l.Magnitude > 0.05 then targetUp = l.Unit end
			up = targetUp
		end
	end

	-- 6) velocidad perpendicular a la superficie
	local verticalSpeed: number
	if groundHit and not transitioned then
		local err = hoverHeight - groundHit.Distance
		verticalSpeed = math.clamp(err * SlimeConfig.HoverStiffness, -SlimeConfig.MaxSnapSpeed, SlimeConfig.MaxSnapSpeed)
	elseif grounded then
		verticalSpeed = 0
	else
		verticalSpeed = upSpeed
	end

	-- 7) velocidad tangente (con inercia)
	local speed = (up.Y < SlimeConfig.FloorYThreshold) and SlimeConfig.ClimbSpeed or SlimeConfig.WalkSpeed
	local rate = grounded and SlimeConfig.GroundAccel or SlimeConfig.AirAccel
	tangentVelocity = projectOnPlane(tangentVelocity, up):Lerp(move * speed, 1 - math.exp(-rate * dt))

	vel.MaxForce = root.AssemblyMass * SlimeConfig.MaxAccel
	vel.VectorVelocity = tangentVelocity + up * verticalSpeed

	-- 8) orientacion: up del personaje = up de la superficie, mirando hacia donde camina
	local look = projectOnPlane(facing, up)
	if look.Magnitude < 0.05 then
		look = projectOnPlane(root.CFrame.LookVector, up)
		if look.Magnitude < 0.05 then look = projectOnPlane(root.CFrame.UpVector, up) end
		if look.Magnitude < 0.05 then look = anyTangent(up) end
	end
	facing = look.Unit
	if move.Magnitude > 0.1 then
		facing = move.Unit
	end
	align.CFrame = CFrame.fromMatrix(Vector3.zero, facing:Cross(up), up, -facing)

	-- 9) servidor
	syncServer(now)
end

----------------------------------------------------------------------
-- API publica
----------------------------------------------------------------------

function MovementController:GetUp(): Vector3
	return targetUp
end

function MovementController:GetSubject(): BasePart?
	return humanoidRootPart
end

function MovementController:Init()
	print("Movement controller para: ", localPlayer.Name)

	UserInputService.JumpRequest:Connect(function()
		jumpRequestedAt = os.clock()
	end)

	localPlayer.CharacterAdded:Connect(function(newCharacter)
		bindCharacter(newCharacter)
		RemoteEvents.SetClimbingState:FireServer(false, Vector3.yAxis)
	end)
	if localPlayer.Character then
		bindCharacter(localPlayer.Character)
	end

	RunService.PreSimulation:Connect(step)
end

return MovementController