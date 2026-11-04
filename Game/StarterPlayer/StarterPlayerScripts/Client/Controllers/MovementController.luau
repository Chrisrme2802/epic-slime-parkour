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

-- constantes
local NORMAL_CHANGE_DOT = 0.98  -- detectar superficie distinta
local SURFACE_BLEND_DOT = 0.7   -- pendientes
local JUMP_BUFFER = 0.15
local COYOTE_TIME = 0.12
local BASIS_HOLD = 0.4          -- seg que se conserva la referencia de input tras cambiar de cara
local MIN_INERTIA_PROBE = 1     -- velocidad tangente minima para usarla como direccion de sonda
local CORNER_TIME = 0.6         -- seg maximos rodeando una arista antes de darla por perdida

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

-- referencia de input (se "congela" un instante al cambiar de cara)
local lastForward = -Vector3.zAxis
local heldForward: Vector3? = nil
local holdUntil = 0

-- seguimiento de esquina: punto de la cara nueva hacia el que nos "enrollamos"
local cornerPoint: Vector3? = nil
local cornerUntil = 0

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

-- privadas
local function projectOnPlane(v: Vector3, normal: Vector3): Vector3
	return v - v:Dot(normal) * normal
end

local function anyTangent(up: Vector3): Vector3
	local ref = math.abs(up.X) < 0.9 and Vector3.xAxis or Vector3.zAxis
	return ref:Cross(up).Unit
end

-- rota el vector v con la misma rotacion que lleva 'from' a 'to'
local function rotateBetween(v: Vector3, from: Vector3, to: Vector3): Vector3
	local axis = from:Cross(to)
	local sinA = axis.Magnitude
	if sinA < 1e-4 then return v end
	local angle = math.atan2(sinA, from:Dot(to))
	return CFrame.fromAxisAngle(axis.Unit, angle):VectorToWorldSpace(v)
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
	lastForward = -Vector3.zAxis
	heldForward = nil
	holdUntil = 0
	cornerPoint = nil
	cornerUntil = 0
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

	-- nosotros manejamos movimiento
	hum.AutoRotate = false
	hum.PlatformStand = true

	createPhysicsObjects(root)
	resetState()
end

-- "adelante" tangente a la superficie, segun la camara (o la referencia congelada tras una transicion)
local function computeForward(up: Vector3, now: number): Vector3
	local held = heldForward
	if held and now < holdUntil then
		local f = projectOnPlane(held, up)
		if f.Magnitude > 0.001 then
			lastForward = f.Unit
			return lastForward
		end
	end

	local camera = workspace.CurrentCamera
	if camera then
		local camCF = camera.CFrame
		local forward = projectOnPlane(camCF.LookVector, up)
		if forward.Magnitude < 0.3 then
			forward = projectOnPlane(camCF.UpVector, up) -- camara mirando casi de frente/arriba abajo
		end
		if forward.Magnitude > 0.001 then
			lastForward = forward.Unit
			return lastForward
		end
	end

	local f = projectOnPlane(lastForward, up)
	if f.Magnitude > 0.001 then
		lastForward = f.Unit
	else
		lastForward = anyTangent(up)
	end
	return lastForward
end

-- inputs respecto a tangente de superficie
local function getMoveDirection(up: Vector3, forward: Vector3): Vector3
	local input = getRawInput()
	if input.Magnitude < 0.01 then return Vector3.zero end

	local right = forward:Cross(up)
	local dir = right * input.X + forward * -input.Z
	if dir.Magnitude > 1 then dir = dir.Unit end
	return dir
end

-- red
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

	local forwardNow = computeForward(up, now)
	local move = getMoveDirection(up, forwardNow)
	local moveDir = move.Magnitude > 0.01 and move.Unit or nil

	-- salto
	if (now - jumpRequestedAt) < JUMP_BUFFER and (grounded or (coyoteAvailable and (now - lastGroundedTime) < COYOTE_TIME)) then
		upSpeed = SlimeConfig.JumpPower
		grounded = false
		wasGrounded = false
		coyoteAvailable = false
		jumpRequestedAt = -math.huge
		cornerPoint = nil
	end

	-- 1) pared por delante (suelo O aire; no depende de upSpeed ni de wasGrounded)
	--    direccion de sonda: la que pide el jugador o, si no hay input, la inercia tangente
	local transitioned = false
	local probeDir = moveDir
	if not probeDir and tangentVelocity.Magnitude > MIN_INERTIA_PROBE then
		probeDir = tangentVelocity.Unit
	end
	if probeDir then
		local wall = workspace:Raycast(pos, probeDir * SlimeConfig.RayDistance, rayParams)
		if wall and wall.Normal:Dot(up) < SURFACE_BLEND_DOT then
			targetUp = wall.Normal
			transitioned = true
			cornerPoint = nil
		end
	end

	-- 2) suelo bajo los pies (solo si NO subimos: si no, anula el salto)
	local groundHit: RaycastResult? = nil
	if not transitioned and upSpeed <= 0 then
		groundHit = workspace:Raycast(pos, -up * stickDistance, rayParams)
	end

	if groundHit then
		local n = groundHit.Normal
		if n:Dot(up) > SURFACE_BLEND_DOT then
			-- pendiente / superficie curva
			local blended = up:Lerp(n, 1 - math.exp(-SlimeConfig.SurfaceBlendRate * dt))
			targetUp = blended.Unit
		else
			-- cambio brusco de cara justo bajo nosotros
			targetUp = n
			transitioned = true
		end
		grounded = true
		cornerPoint = nil -- hay suelo real bajo los pies: la esquina ya esta resuelta
	elseif transitioned then
		grounded = true
	elseif cornerPoint and now < cornerUntil and upSpeed <= 0 then
		-- rodeando una arista: el rayo aun no ve la cara nueva, pero seguimos pegados
		grounded = true
	elseif wasGrounded and upSpeed <= 0 then
		-- 3) arista convexa: buscar la cara lateral por debajo del plano
		local edgeDir = probeDir or facing
		local origin = pos - up * (hoverHeight + 0.5)
		local wrap = workspace:Raycast(origin, -edgeDir * SlimeConfig.EdgeProbeDistance, rayParams)
		if wrap and wrap.Normal:Dot(edgeDir) > 0.5 then
			targetUp = wrap.Normal
			transitioned = true
			grounded = true
			cornerPoint = wrap.Position
			cornerUntil = now + CORNER_TIME
		else
			grounded = false
		end
	else
		grounded = false
	end

	-- 4) tras cambiar de superficie: limpiar estado y re-medir con la NUEVA normal
	if transitioned then
		local newUp = targetUp

		-- el "adelante" del jugador gira con la superficie (evita que W te devuelva por donde viniste)
		local newForward = rotateBetween(forwardNow, up, newUp)
		heldForward = newForward
		holdUntil = now + BASIS_HOLD

		up = newUp
		upSpeed = 0

		-- inercia: quitar la parte de la velocidad que atraviesa la nueva cara (no empuja al vacio)
		tangentVelocity = projectOnPlane(tangentVelocity, up)

		-- recalcular el movimiento deseado con la referencia girada
		local f2 = projectOnPlane(newForward, up)
		if f2.Magnitude > 0.001 then
			move = getMoveDirection(up, f2.Unit)
		else
			move = projectOnPlane(move, up)
		end

		-- hover inmediato: si ya vemos la cara nueva, medir ahora mismo
		groundHit = workspace:Raycast(pos, -up * stickDistance, rayParams)
		if groundHit then
			cornerPoint = nil
		end
	else
		up = targetUp
	end

	if grounded then
		coyoteAvailable = true
		lastGroundedTime = now
		upSpeed = 0
	end

	-- gravedad (a lo largo de -up)
	if not grounded then
		upSpeed = math.max(upSpeed - SlimeConfig.Gravity * dt, -SlimeConfig.MaxFallSpeed)
		if (now - lastGroundedTime) > SlimeConfig.AirResetTime then
			-- volver a gravedad normal
			local l = targetUp:Lerp(Vector3.yAxis, 1 - math.exp(-2 * dt))
			if l.Magnitude > 0.05 then targetUp = l.Unit end
			up = targetUp
		end
	end

	-- velocidad perpendicular a superficie (+ "tiron" tangente si rodeamos una esquina)
	local verticalSpeed: number
	local cornerPull = Vector3.zero
	local cp = cornerPoint
	if groundHit and grounded then
		local err = hoverHeight - groundHit.Distance
		verticalSpeed = math.clamp(err * SlimeConfig.HoverStiffness, -SlimeConfig.MaxSnapSpeed, SlimeConfig.MaxSnapSpeed)
	elseif grounded and cp and now < cornerUntil then
		-- el rayo hacia -up aun pasa "por fuera" de la cara nueva. Vamos hacia el punto de hover
		-- sobre esa cara: baja (tangente) y se acerca/separa (normal) hasta que el rayo la vea.
		local toTarget = (cp + up * hoverHeight) - pos
		verticalSpeed = math.clamp(toTarget:Dot(up) * SlimeConfig.HoverStiffness, -SlimeConfig.MaxSnapSpeed, SlimeConfig.MaxSnapSpeed)
		cornerPull = projectOnPlane(toTarget, up) * SlimeConfig.HoverStiffness
		if cornerPull.Magnitude > SlimeConfig.MaxSnapSpeed then
			cornerPull = cornerPull.Unit * SlimeConfig.MaxSnapSpeed
		end
	elseif grounded then
		verticalSpeed = 0
	else
		verticalSpeed = upSpeed
	end

	-- velocidad tangente
	local speed = (up.Y < SlimeConfig.FloorYThreshold) and SlimeConfig.ClimbSpeed or SlimeConfig.WalkSpeed
	local rate = grounded and SlimeConfig.GroundAccel or SlimeConfig.AirAccel
	local desired = move * speed + cornerPull
	tangentVelocity = projectOnPlane(tangentVelocity, up):Lerp(desired, 1 - math.exp(-rate * dt))

	vel.MaxForce = root.AssemblyMass * SlimeConfig.MaxAccel
	vel.VectorVelocity = tangentVelocity + up * verticalSpeed

	-- orientacion
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

	syncServer(now)
end

-- api
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