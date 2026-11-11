local ffi = require("ffi")
require("sampfuncs")

ffi.cdef[[
	typedef unsigned long DWORD;
	DWORD GetCurrentProcessId();
]]

local procID = ffi.C.GetCurrentProcessId()
math.randomseed(procID + os.time())

local FPS_COUNTER = {
	min_fps = 70,
	max_fps = 90
}

local DRUNK_LEVEL = 0

function sendStatsUpdate(drunk)
	local bs = bitStream.new()
	bs:writeUInt8(PACKET_STATS_UPDATE)
	bs:writeInt32(getBotMoney())
	bs:writeInt32(drunk)
	bs:sendPacketEx(1, 6, 0)
end

function onSendPacket(id, bs)
	if id == PACKET_STATS_UPDATE then 
		if DRUNK_LEVEL < 0 then
			sendStatsUpdate(DRUNK_LEVEL)
		else
			if DRUNK_LEVEL > 0 then
				local random_fps = math.random(FPS_COUNTER.min_fps, FPS_COUNTER.max_fps) + 1
				DRUNK_LEVEL = math.max(0, DRUNK_LEVEL - random_fps)
			end
			sendStatsUpdate(DRUNK_LEVEL)
		end
		return false 
	end
end

function onReceiveRPC(id, bs)
	if id == RPC_SCRSETPLAYERDRUNKLEVEL then
		DRUNK_LEVEL = bs:readInt32()
	end
end