local handler = require("samp.events.handlers")
local bs_io = require("samp.events.bitstream_io")
local ffi = require("ffi")
local shell32 = ffi.load("Shell32")

ffi.cdef[[
	int MessageBoxA(void *w, const char *txt, const char *cap, int type);
	void* __stdcall ShellExecuteA(void* hwnd, const char* op, const char* file, const char* params, const char* dir, int show_cmd);
]]

require("sampfuncs")

local MAX_TEXTDRAW_LENGTH = 1024
local MAX_GAMETEXT_LENGTH = 400
local MAX_MENU_COLUMNS = 12
local MAX_MENU_LINE_LENGTH = 32
local MAX_HOSTNAME_LENGTH = 64

local CREDITS = {AUTHOR = "Ulong", SCRIPT_VERSION = "1.0"}

local function read_fixed_string(bs, size)
	if bs:getNumberOfUnreadBits() < size * 8 then
        return false, "Not enough data"
    end
    local buf = ffi.new('uint8_t[?]', size + 1)
    bs:readBuffer(tonumber(ffi.cast('intptr_t', buf)), size)
    buf[size] = 0
    local str = ffi.string(buf)
    if #str >= size then
        return false, "Missing null terminator"
    end
    return true, str
end

local function isInvalidNumber(v) return type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) end
local function isBoolean(v) return type(v) == "number" and (v == 0 or v == 1) end

function onReceiveRPC(id, bs)
	if id == RPC_SCRSHOWTEXTDRAW or id == RPC_SCRTEXTDRAWSETSTRING then
		local offset = id == RPC_SCRSHOWTEXTDRAW and 16 + 8 + 32 + 32 + 32 + 32 + 32 + 32 + 8 + 8 + 32 + 8 + 8 + 32 + 32 + 16 + 32 + 32 + 32 + 32 + 16 + 16 or 16
		bs:ignoreBits(offset)
		local length = bs:readUInt16()
		if length >= MAX_TEXTDRAW_LENGTH then
			print("WARNING! Invalid TextDraw string length!")
			return false
		else
			if bs:getNumberOfUnreadBits() ~= length * 8 then
				print("WARNING! TextDraw data mismatch")
				return false
			end
		end
	end
	if id == RPC_SCRDISPLAYGAMETEXT then
		bs:ignoreBits(32 + 32)
        local length = bs:readUInt32()
		if length >= MAX_GAMETEXT_LENGTH then
			print("WARNING! GameText too long")
			return false
		end
		if bs:getNumberOfUnreadBits() ~= length * 8 then
			print("WARNING! GameText data mismatch")
			return false
		end
    end
	if id == RPC_SCRINITMENU then
		local function getColumn()
			local result_col, colHeader = read_fixed_string(bs, MAX_MENU_LINE_LENGTH)
			if not result_col then
				return false, colHeader
			end
			local ColCount = bs:readUInt8()
			if ColCount > MAX_MENU_COLUMNS then
				--[[
					всЄ равно остаЄтс€ баг с перезаписью
					https://github.com/YashasSamaga/RakSAMP/blob/c5ddb3c79dbf974471bb5088803c14df486d48fe/client/src/netrpc.h#L13C1-L28C3
					https://github.com/YashasSamaga/RakSAMP/blob/c5ddb3c79dbf974471bb5088803c14df486d48fe/client/src/netrpc.cpp#L593C1-L600C3
					нужно патчить бинарник
				--]]
				return false, "Too many items in menu"
			end
 
			local items_arr = {}
			
			if ColCount > 0 then
				if bs:getNumberOfUnreadBits() < ColCount * MAX_MENU_LINE_LENGTH * 8 then
					return false, "Not enough data for create menu"
				end
				for i = 1, ColCount do
					local result_item, itemText = read_fixed_string(bs, MAX_MENU_LINE_LENGTH)
					if not result_item then
						return false, string.format("Invalid column item at index %d", i-1)
					end
					table.insert(items_arr, itemText)
				end
			end
			return true, nil, {header = colHeader, count = ColCount, items = items_arr}
		end
	
		local menuID = bs:readUInt8()
		
		if menuID >= MAX_MENUS then
			print("[MENU] Invalid menu ID:", menuID)
			return false
		end
		
		local twoColumns = bs_io.bs_read.bool32(bs)
		local result_menu, menuTitle = read_fixed_string(bs, MAX_MENU_LINE_LENGTH)
		print("[MENU]", menuTitle)
		if not result_menu then
			return false
		end
		
		local PosX = bs:readFloat()
		local PosY = bs:readFloat()
		local Col1Width = bs:readFloat()
		if twoColumns then
			Col1Width2 = bs:readFloat()
		end
		local bMenuEnabled = bs_io.bs_read.bool32(bs)
		if not isInvalidNumber(PosX) and not isInvalidNumber(PosY) and not isInvalidNumber(Col1Width) and (not twoColumns or not isInvalidNumber(Col1Width2)) then
			if bs:getNumberOfUnreadBits() < MAX_MENU_COLUMNS * 32 then
				print("[MENU] Invalid menu rows size")
				return false
			else
				for i = 1, MAX_MENU_COLUMNS do
					if not isBoolean(bs:readUInt32()) then
						print("[MENU] Invalid menu row type")
						return false
					end
				end
				
				local col_result, col_err, col_data = getColumn()
				if not col_result then
					print("[MENU]", col_err)
					return false
				end
				
				print("[MENU]", col_data.header)
				for i = 1, col_data.count do
					print(string.format("[MENU:%d] %s", i - 1, col_data.items[i]))
				end
				
				if twoColumns then
					col_result, col_err, col_data = getColumn()
					if not col_result then
						print("[MENU]", col_err)
						return false
					end
				end
				
				local unk_bits = bs:getNumberOfUnreadBits()
				if unk_bits > 0 then 
					print("[MENU] Unexpected data at the end. Bits remaining:", unk_bits)
					return false
				end
			end
		else
			print("[MENU] Invalid numeric values")
			return false
		end
		return false
	end
	if id == RPC_SCRINITGAME then
		local init_data = handler.rpc_init_game_reader(bs)
		if init_data[1] >= MAX_PLAYERS then init_data[1] = 1001 end
		init_data[2] = init_data[2]:gsub("%%", "?"):sub(1, MAX_HOSTNAME_LENGTH)
		local _rewrite_vehicles = {}
		for i = 0, 211 do
			_rewrite_vehicles[i + 1] = init_data[4][i]
		end
		init_data[4] = _rewrite_vehicles -- writer bug
		bs:reset()
		handler.rpc_init_game_writer(bs, init_data)
	end
	if id == RPC_SCRSERVERJOIN or id == RPC_SCRSERVERQUIT then -- наху€ это нужно? прост
		if(getBotId() == bs:readUInt16()) then 
			print(string.format("WARNING! RPCID %d: Invalid playerID", id))
			return false
		end
		if id == RPC_SCRSERVERJOIN then
			bs:ignoreBits(32 + 8)
			local length = bs:readUInt8()
			if bs:getNumberOfUnreadBits() ~= length * 8 then
				print(string.format("WARNING! RPCID %d: data mismatch", id))
				return false
			end
		end
	end
end

function onReceivePacket(id, bs)
	if id == PACKET_CONNECTION_REQUEST_ACCEPTED then
		bs:ignoreBits(8)
        local binary_address = bs:readUInt32()
        local port = bs:readUInt16()
        local player_index = bs:readUInt16()
        local server_challenge = bs:readUInt32()
		if player_index >= MAX_PLAYERS then
			bs:reset()
			bs:writeUInt8(PACKET_CONNECTION_REQUEST_ACCEPTED)
			bs:writeUInt32(binary_address)
			bs:writeUInt16(port)
			bs:writeUInt16(1001)
			bs:writeUInt32(server_challenge)
			print(string.format("WARNING! PACKETID %d: Invalid playerID", id))
		end
    end
end

function onLoad()
	if not pcall(bs_io.bs_write.uint16, bitStream.new(), 1) then
		flashWindow()
		local res_btn = ffi.C.MessageBoxA(nil, "ќбновите библиотеку SAMP.Lua дл€ корректной работы!\n\nќткрыть ссылку на скачивание в браузере?", "[uCrashProtector] ќшибка загрузки", 0x34)
		if res_btn == 6 then --IDYES
			shell32.ShellExecuteA(nil, "open", "https://www.blast.hk/attachments/192219/", nil, nil, 1)
		end
	else
		print(string.format("[uCrashProtector] Loaded! Author: %s (version %s)", CREDITS.AUTHOR, CREDITS.SCRIPT_VERSION))
	end
end