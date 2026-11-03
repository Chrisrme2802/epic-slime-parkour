local SlimeConfig = {}

-- movimiento
SlimeConfig.WalkSpeed = 16
SlimeConfig.ClimbSpeed = 12
SlimeConfig.JumpPower = 50
SlimeConfig.Gravity = 196.2
SlimeConfig.MaxFallSpeed = 150
SlimeConfig.GroundAccel = 20
SlimeConfig.AirAccel = 5
SlimeConfig.MaxAccel = 2000

-- adhesion a superficies
SlimeConfig.RayDistance = 2.5
SlimeConfig.EdgeProbeDistance = 3
SlimeConfig.StickMargin = 1.5
SlimeConfig.HoverHeight = nil
SlimeConfig.HoverStiffness = 20
SlimeConfig.MaxSnapSpeed = 30
SlimeConfig.SurfaceBlendRate = 12
SlimeConfig.AirResetTime = 2
SlimeConfig.FloorYThreshold = 0.8

-- red
SlimeConfig.NetworkInterval = 0.1

-- camara
SlimeConfig.CameraDistance = 14
SlimeConfig.CameraHeight = 2
SlimeConfig.CameraSensitivity = 0.003
SlimeConfig.CameraUpSmooth = 8

-- estetica
SlimeConfig.DefaultColor = Color3.fromRGB(103, 203, 228)
SlimeConfig.Transparency = 0.2

return SlimeConfig