local bit = require("bit")
require("sampfuncs")

local module = {}

module._NAME = "VehicleDamageStatus"
module._AUTHOR = "Ulong"
module._VERSION = "1.0.0"
module._DESCRIPTION = "Manipulate damage status of vehicle components"

module.VEH_COMP_POOL = {}
module.onVehicleDamageStatusChanged = function(vehicleId, updatedComponents, streamed) end

module.COMPONENTS = {
	DOORS = {
        HOOD          		= 0x0,
        TRUNK         		= 0x1,
        DRIVER_DOOR   		= 0x2,
        PASSENGER_DOOR 		= 0x3,
		STATES = {
			NORMAL     		= 0x0,
			OPENED     		= 0x1,
			DAMAGED    		= 0x2,
			REMOVED   	 	= 0x4
		}
    },
	PANELS = {
        FRONT_LEFT     		= 0x0,
        FRONT_RIGHT    		= 0x1,
        BACK_LEFT      		= 0x2,
        BACK_RIGHT     		= 0x3,
        WINDSHIELD     		= 0x4,
        FRONT_BUMPER   		= 0x5,
        BACK_BUMPER			= 0x6,
        STATES = {
			NORMAL        	= 0x0,
			CRUSHED      	= 0x1,
            HANGING_LOOSE 	= 0x2,
            REMOVED       	= 0x3
		}
	},
	TIRES = {
		BACK_RIGHT			= 0x0,
		FRONT_RIGHT			= 0x1,
		BACK_LEFT			= 0x2,
		FRONT_LEFT			= 0x3,
		STATES = {
			NORMAL			= 0x0,
			POPPED			= 0x1,
		}
	},
	LIGHTS = {
		FRONT_LEFT			= 0x0,
		FRONT_RIGHT			= 0x2,
		BACK_LIGHT			= 0x6,
		STATES = {
			NORMAL			= 0x0,
			BROKEN      	= 0x1
		}
	},
	UPDATE = {
		door = "door",
		panel = "panel",
		light = "light",
		tire = "tire"
	}
}

print(string.format("[%s] Module loaded! Author %s. Version %s", module._NAME, module._AUTHOR, module._VERSION))

local function checkDamageStatusUpdated(vehicleId, new_components)
    local old_components = module.VEH_COMP_POOL[vehicleId]
	if old_components ~= nil then
		local flags = {}
		for key in pairs(module.COMPONENTS.UPDATE) do
			flags[key] = (old_components[key] ~= new_components[key])
		end
		module.VEH_COMP_POOL[vehicleId] = new_components
		module.onVehicleDamageStatusChanged(vehicleId, flags, true)
	end
end

local function sendUpdateVehicleDamageStatus(vehicleId, data)
	local bs = bitStream.new()
	bs:writeUInt16(vehicleId)
	bs:writeUInt32(data.panel)
	bs:writeUInt32(data.door)
	bs:writeUInt8(data.light)
	bs:writeUInt8(data.tire)
	bs:sendRPC(RPC_DAMAGEVEHICLE)
end

registerHandler("onReceiveRPC", function(id, bs)
	if id == RPC_SCRWORLDVEHICLEADD then
		local vehicleId = bs:readUInt16()
		bs:setReadOffset(16 + 32 + 32 + 32 + 32 + 32 + 8 + 8 + 32 + 8)
		module.VEH_COMP_POOL[vehicleId] = {door = bs:readUInt32(), panel = bs:readUInt32(), light = bs:readUInt8(), tire = bs:readUInt8()}
		module.onVehicleDamageStatusChanged(vehicleId, {door = true, panel = true, light = true, tire = true}, false)
	elseif id == RPC_DAMAGEVEHICLE then
		local vehicleId = bs:readUInt16()
		local updated_comp = {}
		updated_comp.panel = bs:readUInt32()
		updated_comp.door = bs:readUInt32()
		updated_comp.light = bs:readUInt8()
		updated_comp.tire = bs:readUInt8()
		checkDamageStatusUpdated(vehicleId, updated_comp)
	elseif id == RPC_SCRWORLDVEHICLEREMOVE then
		local vehicleId = bs:readUInt16()
		module.VEH_COMP_POOL[vehicleId] = nil
	end
end)

registerHandler("onReceivePacket", function(id, bs)
	if id == PACKET_DISCONNECTION_NOTIFICATION or id == PACKET_CONNECTION_LOST then
		module.VEH_COMP_POOL = {}
	end
end)

function module.getVehicleDoorState(vehicleId, door, state)
	if module.VEH_COMP_POOL[vehicleId] ~= nil then
		local all_doors = module.VEH_COMP_POOL[vehicleId].door
		return bit.band(bit.rshift(all_doors, (8 * door)), state) ~= 0
	end
	return false
end

function module.setVehicleDoorState(door, state)
    local vehicleId = getBotVehicle()
	if vehicleId ~= 0 then
		if module.VEH_COMP_POOL[vehicleId] ~= nil then
			local all_doors = module.VEH_COMP_POOL[vehicleId].door
			all_doors = bit.bor(all_doors, bit.lshift(state, (8 * door)))
            if state == module.COMPONENTS.DOORS.STATES.NORMAL then
                all_doors = bit.band(all_doors, bit.bnot(bit.lshift(0x7, (8 * door))))
            end
			module.VEH_COMP_POOL[vehicleId].door = all_doors
			sendUpdateVehicleDamageStatus(vehicleId, module.VEH_COMP_POOL[vehicleId])
			return true
		end
	end
	return false
end

function module.getVehiclePanelState(vehicleId, panel, state)
    if module.VEH_COMP_POOL[vehicleId] ~= nil then
		local all_panels = module.VEH_COMP_POOL[vehicleId].panel
        return bit.band(bit.rshift(all_panels, (4 * panel)), 0x0F) == state
    end
    return false
end

function module.setVehiclePanelState(panel, state)
    local vehicleId = getBotVehicle()
    if vehicleId ~= 0 then
        if module.VEH_COMP_POOL[vehicleId] ~= nil then
            local all_panels = module.VEH_COMP_POOL[vehicleId].panel
			all_panels = bit.bor(all_panels, bit.lshift(state, (4 * panel)))
            if state == module.COMPONENTS.PANELS.STATES.NORMAL then
				all_panels = bit.band(all_panels, bit.bnot(bit.lshift(0x0F, (4 * panel))))
            end
            module.VEH_COMP_POOL[vehicleId].panel = all_panels
            sendUpdateVehicleDamageStatus(vehicleId, module.VEH_COMP_POOL[vehicleId])
            return true
        end
    end
    return false
end

function module.getVehicleTireState(vehicleId, tire)
    if module.VEH_COMP_POOL[vehicleId] ~= nil then
        local all_tires = module.VEH_COMP_POOL[vehicleId].tire
        return bit.band(bit.rshift(all_tires, tire), 1) == module.COMPONENTS.TIRES.STATES.NORMAL
    end
    return false
end

function module.setVehicleTireState(tire, state)
    local vehicleId = getBotVehicle()
    if vehicleId ~= 0 then
        if module.VEH_COMP_POOL[vehicleId] ~= nil then
            local all_tires = module.VEH_COMP_POOL[vehicleId].tire
			all_tires = bit.bor(all_tires, bit.lshift(1, tire))
            if state == module.COMPONENTS.TIRES.STATES.NORMAL then
                all_tires = bit.band(all_tires, bit.bnot(bit.lshift(1, tire)))
            end
            module.VEH_COMP_POOL[vehicleId].tire = all_tires
            sendUpdateVehicleDamageStatus(vehicleId, module.VEH_COMP_POOL[vehicleId])
            return true
        end
    end
    return false
end

function module.getVehicleLightState(vehicleId, light)
    if module.VEH_COMP_POOL[vehicleId] ~= nil then
        local all_lights = module.VEH_COMP_POOL[vehicleId].light
		return bit.band(all_lights, bit.lshift(1, light)) == module.COMPONENTS.LIGHTS.STATES.NORMAL
    end
    return false
end

function module.setVehicleLightState(light, state)
    local vehicleId = getBotVehicle()
    if vehicleId ~= 0 then
        if module.VEH_COMP_POOL[vehicleId] ~= nil then
            local all_lights = module.VEH_COMP_POOL[vehicleId].light
			all_lights = bit.bor(all_lights, bit.lshift(1, light))
            if state == module.COMPONENTS.LIGHTS.STATES.NORMAL then
				all_lights = bit.band(all_lights, bit.bnot(bit.lshift(1, light)))
            end
            module.VEH_COMP_POOL[vehicleId].light = all_lights
            sendUpdateVehicleDamageStatus(vehicleId, module.VEH_COMP_POOL[vehicleId])
            return true
        end
    end
    return false
end

for k, v in pairs(module.COMPONENTS) do
    _G[k] = v
end

return module