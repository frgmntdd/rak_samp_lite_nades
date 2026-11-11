local utils = require("samp.events.utils")
local vector3d = require("vector3d")
local ffi = require("ffi")
require("sampfuncs")

ffi.cdef[[
	typedef unsigned long DWORD;
	DWORD GetCurrentProcessId();
]]

local procID = ffi.C.GetCurrentProcessId()
math.randomseed(procID + os.time())

local CREDITS = {AUTHOR = "Ulong", SCRIPT_VERSION = "1.2"}

local AIM_SYNC_RATE = 8
local SPEC_SYNC_RATE = 5

local gl = {
	bot_move = false,
	last_pos = vector3d(0, 0, 0),
	last_rate_time = os.time() + math.random(5, 60),
	aim_info = {},
	is_regular_pos = false,
	cam_pos_offset = vector3d(0, 0, 0),
	custom_spec = {
		pos = vector3d(-1, -1, -1),
		front = vector3d(-1, -1, -1)
	}
}

function genAimSyncInfo(is_static)
	
	local function getRandomVector(lower, greater)
		local function randomSign()
			return math.random(0, 1) == 0 and -1 or 1
		end
		
		local function randomFloat(lower, greater)
			return lower + math.random() * (greater - lower)
		end
		return vector3d(
			randomFloat(lower, greater) * randomSign(),
			randomFloat(lower, greater) * randomSign(),
			randomFloat(lower, greater) * randomSign()
		)
	end
		
	local function getCameraFrontVec(botPos, camPos, useRandom, randValue)
		local vec = botPos - camPos
		if useRandom then
			vec = vec +  getRandomVector(randValue.min, randValue.max)
		end
		vec:normalize()
		return vec
	end

	local function getBotCameraPos(botRot, botPos)
		local angle = -botRot * math.pi / 180
		return vector3d(botPos.x + (-2 * math.sin(angle)), botPos.y + (-2 * math.cos(angle)), botPos.z + 1)
	end
	
	local currBotPos = vector3d(getBotPosition())
	
	if not is_static then
		gl.cam_pos_offset = getRandomVector(0.5, 3.0)
	end

	local resultCamera = getBotCameraPos(getBotRotation(), currBotPos)
	resultCamera = resultCamera + gl.cam_pos_offset
	
	local resultFront = getCameraFrontVec(currBotPos, resultCamera, true, {min = 0.1, max = 0.3})
	
	local result = {
		camMode = getBotVehicle() ~= 0 and 18 or 4,
		camFront = is_static and gl.aim_info.camFront or resultFront,
		camPos = resultCamera,
		aimZ = 0,
		camExtZoom = 63,
		weaponState = 0,
		aspectRatio = 85
	}
	return result
end

function onSendPacket(id, bs)
	if id == PACKET_AIM_SYNC then
		if not gl.bot_move then
			if gl.last_rate_time < os.time() then
				local aim_data = (utils.process_outcoming_sync_data(bs, 'AimSyncData'))[1]
				local isSpectateEnabled = gl.last_rate_time == -1
				
				aim_data.camFront = gl.aim_info.camFront
				aim_data.camPos = isSpectateEnabled and vector3d(getBotPosition()) or gl.aim_info.camPos
				aim_data.camMode = isSpectateEnabled and 15 or gl.aim_info.camMode
				
				if isSpectateEnabled then
					if gl.custom_spec.front.x ~= -1 and gl.custom_spec.front.y ~= -1 and gl.custom_spec.front.z ~= -1 then
						aim_data.camFront = gl.custom_spec.front
					end
					if gl.custom_spec.pos.x ~= -1 and gl.custom_spec.pos.y ~= -1 and gl.custom_spec.pos.z ~= -1 then
						aim_data.camPos = gl.custom_spec.pos
					end
				end
				
				aim_data.aimZ = gl.aim_info.aimZ
				aim_data.camExtZoom = gl.aim_info.camExtZoom
				aim_data.weaponState = gl.aim_info.weaponState
				aim_data.aspectRatio = gl.aim_info.aspectRatio
				gl.last_rate_time = os.time() + math.random(5, 60)
			else
				return false
			end
		else
			gl.bot_move = false
			return false
		end
	end
	if id == PACKET_PLAYER_SYNC or id == PACKET_VEHICLE_SYNC then
		local data = id == PACKET_PLAYER_SYNC and (utils.process_outcoming_sync_data(bs, 'PlayerSyncData'))[1] or (utils.process_outcoming_sync_data(bs, 'VehicleSyncData'))[1]
		if data.position.x ~= gl.last_pos.x or data.position.y ~= gl.last_pos.y or data.position.z ~= gl.last_pos.z then
			gl.bot_move = true
		end
		gl.last_pos = data.position
	elseif id == PACKET_SPECTATOR_SYNC then
		gl.last_rate_time = -1
		bs:sendPacketEx(HIGH_PRIORITY, UNRELIABLE, 0)
		return false
	end
end

function onReceiveRPC(id, bs)
	if id == RPC_SCRSETPLAYERPOS and isBotSpawned() then
		gl.last_pos = vector3d(bs:readFloat(), bs:readFloat(), bs:readFloat())
		setBotPosition(gl.last_pos.x, gl.last_pos.y, gl.last_pos.z)
		gl.aim_info = genAimSyncInfo(gl.is_regular_pos)
		gl.is_regular_pos = true
		gl.last_rate_time = 0
	elseif id == RPC_SCRSETPLAYERCAMERAPOS and not isBotSpawned() then
		setBotPosition(bs:readFloat(), bs:readFloat(), bs:readFloat())
		gl.aim_info = genAimSyncInfo()
	elseif id == RPC_SCRINTERPOLATECAMERA and not isBotSpawned() then
		if bs:readBool() then
			bs:setReadOffset(1 + 32 + 32 + 32)
			setBotPosition(bs:readFloat(), bs:readFloat(), bs:readFloat())
			gl.aim_info = genAimSyncInfo()
		end
	end
end

function onReceivePacket(id, bs)
	if id == PACKET_DISCONNECTION_NOTIFICATION or id == PACKET_CONNECTION_LOST or id == PACKET_CONNECTION_BANNED or id == PACKET_INVALID_PASSWORD then
		gl.is_regular_pos = false
		gl.bot_move = false
		gl.cam_pos_offset = vector3d(0, 0, 0)
	end
end

function onLoad()
	print(string.format("[AimSync FIX] Loaded! Author: %s (version %s)", CREDITS.AUTHOR, CREDITS.SCRIPT_VERSION))
	gl.aim_info = genAimSyncInfo()
	setRate(AIM_SYNC_RATE, 1000)
	setRate(SPEC_SYNC_RATE, 100)
end