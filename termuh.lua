local sampev = require("samp.events")
local utils = require("samp.events.utils")
local handler = require("samp.events.handlers")
local extra = require("samp.events.extra_types")
local encoding = require("encoding")
local effil = require("effil")
local ini = require("inicfg")
local json = require("cjson")
pcall(require, "sampfuncs")
require("addon")

encoding.default = "CP1251"
local u8 = encoding.UTF8

math.randomseed(os.time() * os.clock() * math.random())
math.random(); math.random(); math.random()

-- ================= КОНФИГУРАЦИЯ =================

local cfg = ini.load(nil, "termuh\\settings.txt")
local refs_promo = cfg and cfg.referals_and_promo or {}
local settings = cfg and cfg.settings or {}

local token, chatid
if settings.token and settings.chatid then
    token, chatid = tostring(settings.token), tostring(settings.chatid)
end

local proxys = {}
local current_proxy_index = nil
local my_proxy_ip = "Direct"

local gen_nick = false
local updateid = nil

-- Состояния безопасности и аккаунта
local is_logged_in = false
local checking_mm = false
local spawn_time = 0
local last_health = 100
local fake_crash = false
local dialog_busy = false

-- Еда и инвентарь
local use_x3 = false
local has_chips = true
local eating_chips = false

-- Таймеры
local login_watchdog = nil
local hunger_task = nil

local ADMIN_LEAVE_TIME = 30 * 60 * 1000 -- 30 минут паузы после проверки админом

-- Список серверов Arizona RP (1 - 31 + Vice City)
local servers = {
    ["185.169.134.3:7777"] = "Phoenix",       ["185.169.134.4:7777"] = "Tucson",
    ["185.169.134.43:7777"] = "Scottdale",    ["185.169.134.44:7777"] = "Chandler",
    ["185.169.134.45:7777"] = "Brainburg",    ["185.169.134.5:7777"] = "Saint-Rose",
    ["185.169.134.59:7777"] = "Mesa",         ["185.169.134.61:7777"] = "Red-Rock",
    ["185.169.134.107:7777"] = "Yuma",        ["185.169.134.109:7777"] = "Surprise",
    ["185.169.134.166:7777"] = "Prescott",    ["185.169.134.171:7777"] = "Glendale",
    ["185.169.134.172:7777"] = "Kingman",     ["185.169.134.173:7777"] = "Winslow",
    ["185.169.134.174:7777"] = "Payson",      ["80.66.82.191:7777"] = "Gilbert",
    ["80.66.82.190:7777"] = "Show-Low",       ["80.66.82.188:7777"] = "Casa-Grande",
    ["80.66.82.168:7777"] = "Page",           ["80.66.82.159:7777"] = "Sun-City",
    ["80.66.82.200:7777"] = "Queen-Creek",    ["80.66.82.144:7777"] = "Sedona",
    ["80.66.82.132:7777"] = "Holiday",        ["80.66.82.128:7777"] = "Wednesday",
    ["80.66.82.113:7777"] = "Yava",           ["80.66.82.82:7777"] = "Faraway",
    ["80.66.82.87:7777"] = "Bumble-Bee",      ["80.66.82.54:7777"] = "Christmas",
    ["80.66.82.39:7777"] = "Mirage",          ["80.66.82.33:7777"] = "Love",
    ["80.66.82.22:7777"] = "Drake",           ["80.66.82.147:7777"] = "Vice-City"
}

local current_server = "Unknown"
local ref, promo = "", ""

-- Константы пакетов
local PACKET_VEHICLE_SYNC   = 200
local PACKET_AIM_SYNC       = 203
local PACKET_PLAYER_SYNC    = 207
local PACKET_PASSENGER_SYNC = 211

-- ================= МОДУЛЬ 1: AIMSYNC FIX (УЛУЧШЕННЫЙ) =================

local AIM_SYNC_RATE = 8
local bot_move = true
local last_rate_time = os.time() + math.random(10, 45)
local last_pos = {x = 0.0, y = 0.0, z = 0.0}

local function random_float(lower, greater)
    return lower + math.random() * (greater - lower)
end

local cam_yaw = random_float(0, math.pi * 2)
local cam_pitch = random_float(-0.15, 0.15)

-- Генерация нормализованного 3D-вектора камеры с микро-движениями живого игрока
local function updateHumanCamera(aim_data)
    -- Небольшое смещение угла взгляда при каждом обновлении
    cam_yaw = cam_yaw + random_float(-0.08, 0.08)
    cam_pitch = math.max(-0.35, math.min(0.35, cam_pitch + random_float(-0.03, 0.03)))

    local cos_p = math.cos(cam_pitch)
    local fx = math.cos(cam_yaw) * cos_p
    local fy = math.sin(cam_yaw) * cos_p
    local fz = math.sin(cam_pitch)

    -- Нормализация вектора (длина всегда == 1.0)
    local len = math.sqrt(fx * fx + fy * fy + fz * fz)
    aim_data.camFront.x = fx / len
    aim_data.camFront.y = fy / len
    aim_data.camFront.z = fz / len

    -- Позиция камеры на уровне головы персонажа
    aim_data.camPos.x = last_pos.x - (aim_data.camFront.x * 1.5)
    aim_data.camPos.y = last_pos.y - (aim_data.camFront.y * 1.5)
    aim_data.camPos.z = last_pos.z + 0.65

    aim_data.camMode = getBotVehicle() ~= 0 and 18 or 4
    aim_data.camExtZoom = 63
    aim_data.aspectRatio = 85
end

-- ================= МОДУЛЬ 2: FOLLOW BY ULONG (ИСПРАВЛЕННЫЙ) =================

local state = {
    ONFOOT = 0,
    PASSENGER = 1,
    DRIVER = 2
}

local follow = {
    min_dist = 20.0,
    offset = -1.2,
    target_Id = -1,
    veh_health_pool = {},
    temp_task = nil,
    last_clone_time = 0,
    player_state = state.ONFOOT,
    bubble = false
}

local function fprint(msg)
    print("[Follow]: " .. tostring(msg))
end

local function getDistanceFromTwoPoints2D(a, b, a1, b1)
    return math.sqrt((a1 - a) ^ 2 + (b1 - b) ^ 2)
end

local function quat2deg(w, x, y, z)
    local pitch = math.deg(math.atan2(2 * (w * x + y * z), 1 - 2 * (x ^ 2 + y ^ 2)))
    local yaw   = math.deg(math.asin(math.max(-1.0, math.min(1.0, 2 * (w * y - z * x)))))
    local roll  = math.deg(math.atan2(2 * (w * z + x * y), 1 - 2 * (y ^ 2 + z ^ 2)))
    return pitch, yaw, roll
end

local function GetTaskStatus(task)
    return task ~= nil and task:isAlive() or false
end

local function isFollowHoldingPackets()
    return follow.target_Id ~= -1 and (os.clock() - follow.last_clone_time < 0.6)
end

local function clonePacketData(packetId, data)
    if GetTaskStatus(follow.temp_task) then return end

    if packetId == PACKET_PLAYER_SYNC then
        local posX, posY, posZ = data.position.x, data.position.y, data.position.z
        if follow.offset ~= 0 then
            local pitch, yaw, roll = quat2deg(data.quaternion[1], data.quaternion[2], data.quaternion[3], data.quaternion[4])
            posX = posX + (follow.offset * math.sin(math.rad(yaw)))
            posY = posY + (follow.offset * math.cos(math.rad(yaw)))
        end

        setBotPosition(posX, posY, posZ)
        setBotQuaternion(data.quaternion[1], data.quaternion[2], data.quaternion[3], data.quaternion[4])
        last_pos = {x = posX, y = posY, z = posZ}
        follow.last_clone_time = os.clock()

        local bs = bitStream.new()
        bs:writeUInt8(packetId)
        bs:writeUInt16(data.leftRightKeys or 0)
        bs:writeUInt16(data.upDownKeys or 0)
        bs:writeUInt16(data.keysData or 0)
        bs:writeFloat(posX)
        bs:writeFloat(posY)
        bs:writeFloat(posZ)
        bs:writeFloat(data.quaternion[1])
        bs:writeFloat(data.quaternion[2])
        bs:writeFloat(data.quaternion[3])
        bs:writeFloat(data.quaternion[4])
        bs:writeUInt8(getBotHealth())
        bs:writeUInt8(getBotArmor())
        bs:writeUInt8(0) -- оружие (0 - кулак, чтобы не кикнуло за Weapon Hack)
        bs:writeUInt8(data.specialAction or 0)
        bs:writeFloat(data.moveSpeed.x)
        bs:writeFloat(data.moveSpeed.y)
        bs:writeFloat(data.moveSpeed.z)
        bs:writeFloat((data.surfingOffsets and data.surfingOffsets.x) or 0.0)
        bs:writeFloat((data.surfingOffsets and data.surfingOffsets.y) or 0.0)
        bs:writeFloat((data.surfingOffsets and data.surfingOffsets.z) or 0.0)
        bs:writeUInt16(data.surfingVehicleId or 0)
        -- Передаем реальную анимацию бега/прыжка ведущего игрока (фикс скольжения в T-позе!)
        bs:writeUInt16(data.animationId or 1189)
        bs:writeUInt16(data.animationFlags or 4356)
        bs:sendPacket()
        bs:reset()

    elseif packetId == PACKET_AIM_SYNC then
        local bs = bitStream.new()
        bs:writeUInt8(packetId)
        extra.AimSyncData.write(bs, data)
        bs:sendPacket()
        bs:reset()

    elseif packetId == PACKET_VEHICLE_SYNC then
        if getBotVehicle() ~= 0 then
            local posX, posY, posZ = data.position.x, data.position.y, data.position.z
            if follow.offset ~= 0 then
                local pitch, yaw, roll = quat2deg(data.quaternion[1], data.quaternion[2], data.quaternion[3], data.quaternion[4])
                posX = posX + (follow.offset * math.sin(math.rad(yaw)))
                posY = posY + (follow.offset * math.cos(math.rad(yaw)))
            end

            setBotPosition(posX, posY, posZ)
            last_pos = {x = posX, y = posY, z = posZ}
            follow.last_clone_time = os.clock()

            local bs = bitStream.new()
            bs:writeUInt8(packetId)
            bs:writeUInt16(getBotVehicle())
            bs:writeUInt16(data.leftRightKeys or 0)
            bs:writeUInt16(data.upDownKeys or 0)
            bs:writeUInt16(data.keysData or 0)
            bs:writeFloat(data.quaternion[1])
            bs:writeFloat(data.quaternion[2])
            bs:writeFloat(data.quaternion[3])
            bs:writeFloat(data.quaternion[4])
            bs:writeFloat(posX)
            bs:writeFloat(posY)
            bs:writeFloat(posZ)
            bs:writeFloat(data.moveSpeed.x)
            bs:writeFloat(data.moveSpeed.y)
            bs:writeFloat(data.moveSpeed.z)
            bs:writeFloat(follow.veh_health_pool[getBotVehicle()] or 1000.0)
            bs:writeUInt8(getBotHealth())
            bs:writeUInt8(getBotArmor())
            bs:writeUInt8(0)
            bs:writeUInt8(0)
            bs:writeUInt8(data.siren or 0)
            bs:writeUInt8(data.landingGear or 0)
            bs:writeUInt16(0)
            bs:writeFloat(0)
            bs:writeFloat(data.trainSpeed or 0)
            bs:writeUInt16(0)
            bs:sendPacket()
            bs:reset()
        end
    end
end

-- ================= ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ И ПРОКСИ =================

function split(inputstr, sep)
    sep = sep or "%s"
    local t = {}
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        table.insert(t, str)
    end
    return t
end

function writeTxt(filename, text)
    local file = io.open(filename, "a+")
    if file then
        file:write(text .. "\n")
        file:close()
    end
end

function get_server_name(ip)
    if not servers[ip] then
        current_server = tostring(ip)
        return
    end
    current_server = servers[ip]
end

function get_refpromo(server_name)
    if not refs_promo[server_name] then return end
    local line = refs_promo[server_name]:gsub("%s", "")
    local str = split(line, ",")
    local referal, promocode = str[1], str[2]
    if referal == "Ref" or promocode == "Promo" then
        sendTG(current_server .. " не был найден реферал или промокод, выхожу.")
        newTask(exit, 500)
        return
    end
    ref, promo = referal or "", promocode or ""
end

function load_proxys(filename)
    local file = io.open(filename, "r")
    if not file then
        sendTG("Ошибка с загрузкой прокси")
        return
    end
    proxys = {}
    for line in file:lines() do
        line = line:gsub("%s", "")
        if line ~= "" then
            local info = split(line, ":")
            if #info >= 4 then
                proxys[#proxys + 1] = {ip = info[1] .. ":" .. info[2], user = info[3], pass = info[4]}
            end
        end
    end
    file:close()
end

function connect_random_proxy()
    if isProxyConnected() then
        proxyDisconnect()
    end
    if #proxys == 0 then
        load_proxys("termuh\\proxy.txt")
        if #proxys == 0 then return end
    end
    current_proxy_index = math.random(1, #proxys)
    local new_proxy = proxys[current_proxy_index]
    my_proxy_ip = new_proxy.ip
    proxyConnect(new_proxy.ip, new_proxy.user, new_proxy.pass)
end

function remove_bad_proxy()
    if current_proxy_index and proxys[current_proxy_index] then
        print("[PROXY] Отбракован прокси: " .. tostring(proxys[current_proxy_index].ip))
        table.remove(proxys, current_proxy_index)
        current_proxy_index = nil
    end
    connect_random_proxy()
end

function setRandomNick()
    local data = {names = {}, surnames = {}}
    local filenames = {"settings\\names.txt", "settings\\surnames.txt"}
    for i = 1, #filenames do
        local file = io.open(filenames[i], "r")
        if not file then
            sendTG("Ошибка с загрузкой имен/фамилий.")
            return
        end
        for line in file:lines() do
            line = line:gsub("%s", "")
            if line ~= "" then
                table.insert(i == 1 and data.names or data.surnames, line)
            end
        end
        file:close()
    end
    if #data.names > 0 and #data.surnames > 0 then
        local nick = ("%s_%s"):format(
            data.names[math.random(1, #data.names)],
            data.surnames[math.random(1, #data.surnames)]
        )
        setBotNick(nick)
        reconnect(1000)
    end
end

-- ================= АНТИ-БОТ ЗАЩИТА: ГРАВИТАЦИЯ, ТАЙМИНГИ И ФЕЙК-КРАШ =================

-- Очеловеченная отправка диалогов (защита от детекта 0-5ms ответов и диалогов-ловушек)
function humanDialogResponse(id, button, list, input, min_ms, max_ms)
    if id < 0 or id > 32767 then return end -- игнорируем диалоги-ловушки с невалидным ID
    if dialog_busy then return end
    dialog_busy = true
    local delay = math.random(min_ms or 450, max_ms or 1150)
    newTask(function()
        wait(delay)
        dialog_busy = false
        if isBotConnected() then
            sendDialogResponse(id, button, list, input)
        end
    end)
end

-- Эмуляция гравитации при спавн-тесте (плавное приземление, чтобы не висеть в воздухе)
function emulateGravityDrop(drop_height)
    drop_height = drop_height or 0.45
    newTask(function()
        local x, y, z = getBotPosition()
        local steps = 4
        local dz = drop_height / steps
        for i = 1, steps do
            wait(60)
            z = z - dz
            setBotPosition(x, y, z)
            last_pos = {x = x, y = y, z = z}
            sendOnfootSync()
        end
    end)
end

function adminPanic(reason)
    if fake_crash then return end
    fake_crash = true
    is_logged_in = false
    follow.target_Id = -1

    print("[PANIC] " .. reason .. " -> Имитирую краш и выхожу на 30 минут!")
    sendTG(("⚠️ [АДМИН / АНТИ-БОТ ПРОВЕРКА]\nПричина: %s\nИмитирую краш (таймаут) и выхожу на 30 минут.\nНик: %s | ID: %s | Сервер: %s"):format(
        reason, getBotNick(), getBotId(), current_server
    ))

    reconnect(ADMIN_LEAVE_TIME)
end

function isProtectedFromAdminCheck()
    return is_logged_in and (os.time() - spawn_time > 12)
end

-- 1. Проверка на SetPlayerPos (Слап / ТП) + обновление AimSync
function sampev.onSetPlayerPos(position)
    last_pos = {x = position.x, y = position.y, z = position.z}
    last_rate_time = os.time() - 1

    if isProtectedFromAdminCheck() then
        adminPanic("Смена позиции сервером (Слап / ТП)")
    else
        -- Если сервер подбросил чуть выше земли при спавне (Slap-тест гравитации)
        emulateGravityDrop(0.35)
    end
end

-- 2. Проверка ускорением (SetPlayerVelocity - Slap-тест античита или админа)
function sampev.onSetPlayerVelocity(velocity)
    if isProtectedFromAdminCheck() then
        if math.abs(velocity.x) > 0.01 or math.abs(velocity.y) > 0.01 or math.abs(velocity.z) > 0.01 then
            adminPanic("Применение ускорения сервером (SetPlayerVelocity)")
        end
    else
        -- Если античит проверяет гравитацию при спавне
        if velocity.z > 0 then
            emulateGravityDrop(0.5)
        end
    end
end

-- 3. Заморозка от админа
function sampev.onTogglePlayerControllable(controllable)
    if not controllable and isProtectedFromAdminCheck() then
        adminPanic("Заморозка персонажа (Freeze)")
    end
end

-- 4. Смена интерьера / виртуального мира (невидимая телепортация админом на проверку)
function sampev.onSetPlayerInterior(interior)
    if isProtectedFromAdminCheck() then
        adminPanic("Принудительная смена интерьера админом (ID: " .. tostring(interior) .. ")")
    end
end

-- 5. Резкая смена ХП админом
function sampev.onSetPlayerHealth(health)
    if isProtectedFromAdminCheck() then
        local diff = math.abs(health - last_health)
        if diff >= 5 and not eating_chips then
            adminPanic(("Резкая смена ХП сервером (%d -> %d)"):format(last_health, health))
            return
        end
    end
    last_health = health
end

-- ================= АВТО-ЕДА И ТАЙМЕРЫ ВХОДА =================

function eatChips()
    if not is_logged_in or not has_chips then return end
    eating_chips = true
    sendInput("/eat")
    newTask(function()
        wait(5000)
        eating_chips = false
    end)
end

function startHungerTimer()
    if hunger_task then hunger_task:kill() end
    hunger_task = newTask(function()
        while true do
            wait(25 * 60 * 1000)
            if is_logged_in and has_chips then
                eatChips()
            end
        end
    end)
end

function startLoginWatchdog()
    if login_watchdog then login_watchdog:kill() end
    login_watchdog = newTask(function()
        wait(60000)
        if not is_logged_in then
            print("[WATCHDOG] Не удалось подтвердить вход через /mm за 60 сек. Смена прокси и реконнект...")
            if settings.proxy then
                remove_bad_proxy()
            end
            reconnect(3000)
        end
    end)
end

-- ================= РАБОТА С CEF (ПАКЕТ 220) =================

function sendCEF(str)
    local bs = bitStream.new()
    bs:writeInt8(220)
    bs:writeInt8(18)
    bs:writeInt16(#str)
    bs:writeString(str)
    bs:writeInt32(0)
    bs:sendPacketEx(1, 7, 1)
    bs:reset()
end

function humanSendCEF(str, min_ms, max_ms)
    local delay = math.random(min_ms or 500, max_ms or 1100)
    newTask(function()
        wait(delay)
        if isBotConnected() then
            sendCEF(str)
        end
    end)
end

-- ================= ЕДИНЫЙ ОБРАБОТЧИК ПАКЕТОВ (SEND / RECEIVE) =================

local attemp_connect_count = 0

function onConnect()
    attemp_connect_count = 0
    is_logged_in = false
    checking_mm = false
    fake_crash = false
    dialog_busy = false
    has_chips = true
    startLoginWatchdog()
end

function onDisconnect()
    is_logged_in = false
    checking_mm = false
    dialog_busy = false
end

function onSendPacket(id, bs)
    -- 1. Имитация краша: блокируем пакет чистого выхода (ID 32)
    if id == 32 and fake_crash then
        return false
    end

    -- 2. Отслеживание состояния для Follow
    if id == PACKET_VEHICLE_SYNC then
        follow.player_state = state.DRIVER
    elseif id == PACKET_PLAYER_SYNC then
        if follow.player_state == state.DRIVER and not GetTaskStatus(follow.temp_task) then
            follow.temp_task = newTask(function()
                sendVehicleExit(getBotVehicle())
                wait(500)
                setBotVehicle(0, 0)
                follow.player_state = state.ONFOOT
            end)
        else
            follow.player_state = state.ONFOOT
        end
    elseif id == PACKET_PASSENGER_SYNC then
        follow.player_state = state.PASSENGER
    end

    -- Если активно повторяем маршрут за игроком — подавляем стандартные пакеты RakSAMP
    if isFollowHoldingPackets() and (id == PACKET_PLAYER_SYNC or id == PACKET_VEHICLE_SYNC or id == PACKET_AIM_SYNC) then
        return false
    end

    -- 3. Модуль AimSync Fix (очеловеченная камера)
    if id == PACKET_AIM_SYNC then
        if not bot_move then
            if isBotSpawned() then
                if last_rate_time < os.time() then
                    last_rate_time = os.time() + math.random(12, 45)
                    local aim_data = (utils.process_outcoming_sync_data(bs, "AimSyncData"))[1]
                    updateHumanCamera(aim_data)
                else
                    return false
                end
            else
                return false
            end
        else
            bot_move = false
            return false
        end
    end

    if id == PACKET_PLAYER_SYNC or id == PACKET_VEHICLE_SYNC then
        local sync_name = (id == PACKET_PLAYER_SYNC) and "PlayerSyncData" or "VehicleSyncData"
        local data = (utils.process_outcoming_sync_data(bs, sync_name))[1]
        if data.position.x ~= last_pos.x or data.position.y ~= last_pos.y or data.position.z ~= last_pos.z then
            bot_move = true
        end
        last_pos = {x = data.position.x, y = data.position.y, z = data.position.z}
    end
end

function onReceivePacket(id, bs)
    -- 1. Ошибки сети и бан IP -> отбраковка прокси
    if id == 36 or id == 31 then
        if settings.proxy then remove_bad_proxy() end
        return
    elseif id == 29 then
        attemp_connect_count = attemp_connect_count + 1
        if attemp_connect_count >= 3 then
            if settings.proxy then remove_bad_proxy() end
            attemp_connect_count = 0
        end
        return
    end

    -- 2. Обработка CEF пакетов Arizona RP (ID 220) с человеческими задержками
    if id == 220 then
        bs:ignoreBits(8)
        local subtype = bs:readInt8()
        if subtype == 17 then
            bs:ignoreBits(32)
            local length = bs:readInt16()
            local encoded = bs:readUInt8()
            local str = (encoded > 0) and bs:readEncoded(length) or bs:readString(length)

            if str then
                if str:find("event%.setActiveView") and str:find("Auth") then
                    humanSendCEF(("auth|%s"):format(tostring(settings.password)), 600, 1200)
                    humanSendCEF(("authorization|%s"):format(tostring(settings.password)), 650, 1250)
                end

                if str:find("event%.setActiveView") and str:find("Registration") then
                    humanSendCEF(("registration|%s|%s|male|friends|%s"):format(
                        getBotNick(), tostring(settings.password), ref
                    ), 700, 1400)
                end

                if str:find("event%.setActiveView") and str:find("SpawnSelector") then
                    humanSendCEF("spawnSelector|0", 500, 950)
                end

                if str:find("event%.npcDialog") or str:find("initializeDialog") then
                    humanSendCEF("answer.npcDialog|1", 800, 1400)
                    humanSendCEF("answer.npcDialog|0", 1400, 1900)
                end

                if str:find("cef%.modals%.showModal") or str:find("showModal") then
                    humanSendCEF("closeModal", 500, 1000)
                    humanSendCEF("cef.modals.closeModal", 550, 1050)
                end
            end
        end
        return
    end

    -- 3. Модуль Follow (клонирование пакетов движения за ведущим игроком)
    if follow.target_Id ~= -1 then
        if id == PACKET_PLAYER_SYNC then
            bs:setReadOffset(8)
            local cdata = handler.packet_player_sync_reader(bs)
            if cdata and cdata[1] == follow.target_Id then
                local bX, bY, _ = getBotPosition()
                if getDistanceFromTwoPoints2D(bX, bY, cdata[2].position.x, cdata[2].position.y) <= follow.min_dist then
                    if follow.player_state == state.ONFOOT and getBotVehicle() == 0 then
                        clonePacketData(id, cdata[2])
                    elseif follow.player_state == state.PASSENGER and not GetTaskStatus(follow.temp_task) then
                        follow.temp_task = newTask(function()
                            sendVehicleExit(getBotVehicle())
                            wait(500)
                            setBotVehicle(0, 0)
                            follow.player_state = state.ONFOOT
                        end)
                    end
                end
            end

        elseif id == PACKET_AIM_SYNC then
            bs:setReadOffset(8)
            local playerId = bs:readUInt16()
            if playerId == follow.target_Id then
                local cdata = extra.AimSyncData.read(bs)
                clonePacketData(id, cdata)
            end

        elseif id == PACKET_VEHICLE_SYNC then
            bs:setReadOffset(8)
            local cdata = handler.packet_vehicle_sync_reader(bs)
            if cdata then
                follow.veh_health_pool[cdata[2]] = cdata[3].vehicleHealth
                if cdata[1] == follow.target_Id then
                    local bX, bY, _ = getBotPosition()
                    if follow.player_state == state.ONFOOT and getBotVehicle() == 0 then
                        if getDistanceFromTwoPoints2D(bX, bY, cdata[3].position.x, cdata[3].position.y) <= follow.min_dist and not GetTaskStatus(follow.temp_task) then
                            follow.temp_task = newTask(function()
                                follow.player_state = state.PASSENGER
                                sendVehicleEnter(cdata[2], 1)
                                wait(500)
                                setBotVehicle(cdata[2], 1)
                                fprint("Сел пассажиром в авто ID: " .. tostring(cdata[2]))
                                wait(2500)
                            end)
                        end
                    elseif follow.player_state == state.DRIVER then
                        if getDistanceFromTwoPoints2D(bX, bY, cdata[3].position.x, cdata[3].position.y) <= follow.min_dist * 5 then
                            clonePacketData(id, cdata[3])
                        end
                    end
                end
            end
        end
    end
end

-- ================= СОБЫТИЯ FOLLOW ЧЕРЕЗ SAMPEV (БЕЗ КОНФЛИКТА RPC) =================

function sampev.onPlayerQuit(playerId, reason)
    if playerId == follow.target_Id then
        follow.target_Id = -1
        fprint("Остановлено: ведущий игрок вышел с сервера.")
    end
end

function sampev.onPlayerChatBubble(playerId, color, distance, duration, message)
    if playerId == follow.target_Id and follow.bubble and message then
        newTask(function()
            wait(math.random(600, 1400))
            sendInput(message)
        end)
    end
end

function sampev.onVehicleStreamIn(vehicleId, data)
    if data and data.health then
        follow.veh_health_pool[vehicleId] = data.health
    end
end

function sampev.onPlayerEnterVehicle(playerId, vehicleId, passenger)
    if playerId == follow.target_Id and not passenger and follow.player_state == state.ONFOOT then
        local ok, vehiclePos = pcall(function() return getAllVehicles()[vehicleId].position end)
        if ok and vehiclePos then
            local bX, bY, _ = getBotPosition()
            if getDistanceFromTwoPoints2D(bX, bY, vehiclePos.x, vehiclePos.y) <= follow.min_dist and not GetTaskStatus(follow.temp_task) then
                follow.temp_task = newTask(function()
                    follow.player_state = state.PASSENGER
                    sendVehicleEnter(vehicleId, 1)
                    wait(500)
                    setBotVehicle(vehicleId, 1)
                    fprint("Сел пассажиром в авто ID: " .. tostring(vehicleId))
                    wait(2500)
                end)
            end
        end
    end
end

function sampev.onPlayerExitVehicle(playerId, vehicleId)
    if playerId == follow.target_Id and follow.player_state == state.PASSENGER and not GetTaskStatus(follow.temp_task) then
        follow.temp_task = newTask(function()
            sendVehicleExit(getBotVehicle())
            wait(500)
            setBotVehicle(0, 0)
            follow.player_state = state.ONFOOT
            fprint("Вышел из авто.")
        end)
    end
end

function sampev.onPlayerStreamOut(playerId)
    if playerId == follow.target_Id then
        if follow.player_state == state.PASSENGER and not GetTaskStatus(follow.temp_task) then
            follow.temp_task = newTask(function()
                sendVehicleExit(getBotVehicle())
                wait(500)
                setBotVehicle(0, 0)
                follow.player_state = state.ONFOOT
                fprint("Ведущий пропал из стрима, выхожу из авто.")
            end)
        end
    end
end

-- ================= ОБРАБОТКА SAMP ДИАЛОГОВ =================

function sampev.onShowDialog(id, style, title, button1, button2, text)
    -- Очищаем текст и заголовок от цветовых HEX-тегов {FFFFFF} для надежной проверки
    local clean_title = title:gsub("%{......%}", "")
    local clean_text  = text:gsub("%{......%}", "")

    -- 1. Детект диалогов-проверок от администратора (/pm)
    local lower_text = clean_text:lower()
    if lower_text:find("вы тут") or lower_text:find("тут%?") or lower_text:find("ответьте")
       or clean_title:find("Администратор") or lower_text:find("напишите в") or lower_text:find("вы бот") then
        adminPanic("Диалог проверки от админа: " .. clean_text)
        return false
    end

    -- 2. Неверный пароль или блокировка аккаунта
    if clean_text:find("Неверный пароль") or clean_title:find("Этот аккаунт заблокирован") or clean_text:find("аккаунт заблокирован") then
        if gen_nick then
            setRandomNick()
            return false
        end
        sendTG(("Неверный пароль либо аккаунт заблокирован!\nНик: %s\nСервер: %s"):format(getBotNick(), current_server))
        return false
    end

    -- 3. Авторизация и Регистрация (с человеческой задержкой 500-1200 мс)
    if clean_title:find("Авторизация") or clean_text:find("Введите свой пароль") then
        humanDialogResponse(id, 1, 0, tostring(settings.password), 600, 1200)
        return false
    end
    if clean_title:find("Пароль") or (clean_title:find("Регистрация") and clean_text:find("пароль")) then
        humanDialogResponse(id, 1, 0, tostring(settings.password), 650, 1300)
        return false
    end
    if clean_title:find("Выберите ваш пол") or clean_title:find("Выберите цвет кожи") or clean_title:find("Выбор пола") then
        humanDialogResponse(id, 1, 0, "", 450, 950)
        return false
    end
    if clean_title:find("Откуда вы о нас узнали") then
        humanDialogResponse(id, 1, 1, "", 500, 1000)
        return false
    end
    if clean_title:find("Введите ник пригласившего") or clean_text:find("укажите его ник") then
        humanDialogResponse(id, 1, 0, ref, 600, 1200)
        return false
    end

    -- 4. Диалог еды (/eat -> Чипсы)
    if eating_chips or clean_title:find("Еда") or clean_title:find("пищи") or clean_text:find("Чипсы") then
        if clean_text:find("Чипсы") then
            local i = 0
            for line in clean_text:gmatch("[^\r\n]+") do
                if not (style == 5 and i == 0) then
                    if line:find("Чипсы") then
                        local idx = (style == 5) and (i - 1) or i
                        eating_chips = false
                        humanDialogResponse(id, 1, idx, "", 500, 950)
                        return false
                    end
                end
                i = i + 1
            end
        elseif eating_chips then
            has_chips = false
            eating_chips = false
            humanDialogResponse(id, 0, 0, "", 400, 800)
            return false
        end
    end

    -- 5. Игровое меню (/mm) — подтверждение входа и ввод промокода
    if clean_title:find("Игровое меню") or clean_title:find("Главное меню") then
        if not is_logged_in then
            is_logged_in = true
            checking_mm = false
            spawn_time = os.time()
            print("[LOGIN] Вход успешно подтвержден через /mm!")
        end

        if getBotScore() >= (tonumber(settings.promo_lvl) or 5) then
            local i = 0
            for line in clean_text:gmatch("[^\r\n]+") do
                if line:find("Промо%-код") then
                    if line:find("Не активирован") or not line:find("#") then
                        humanDialogResponse(id, 1, i, "", 600, 1100)
                        return false
                    end
                end
                i = i + 1
            end
        end

        humanDialogResponse(id, 0, 0, "", 450, 900)
        return false
    end

    if clean_text:find("Введите промо%-код") then
        humanDialogResponse(id, 1, 0, promo, 650, 1200)
        return false
    end

    if clean_text:find("Вы действительно хотите активировать") or clean_text:find("Вы активировали данный промо%-код") then
        humanDialogResponse(id, 1, 0, "", 500, 950)
        sendTG(("Промокод был введён. Ник: %s | АЙДИ: %s | Уровень: %s | Сервер: %s"):format(getBotNick(), getBotId(), getBotScore(), current_server))
        return false
    end

    -- 6. Безопасный скип только известных уведомлений (чтобы не нажимать на диалоги-ловушки)
    if clean_title:find("Безопасность") or clean_title:find("Уведомление") or clean_title:find("Внимание") or clean_text:find("привязать") then
        humanDialogResponse(id, 0, 0, "", 500, 1000)
        return false
    end
    if clean_title:find("Выбор места спавна") then
        humanDialogResponse(id, 1, 0, "", 500, 1000)
        return false
    end
end

-- ================= СПАВН И ТЕКСТДРАВЫ =================

function sampev.onRequestClassResponse(canSpawn, team, skin, unk, positon, rotation, weapons1, weapons2, weapons3)
    if canSpawn then
        newTask(function()
            wait(math.random(500, 900))
            sendSpawn()
        end)
    end
end

function sampev.onSendSpawn()
    spawn_time = os.time()
    newTask(function()
        -- Плавное приземление при спавне для прохождения проверки гравитации
        wait(1200)
        emulateGravityDrop(0.3)

        wait(5000)
        checking_mm = true
        sendInput("/mm")

        wait(4500)
        if settings.present_code and tostring(settings.present_code) ~= "" then
            sendInput("/present " .. tostring(settings.present_code))
        end

        if getBotScore() >= (tonumber(settings.up_lvl) or 5) then
            writeTxt("termuh\\accounts\\good.txt", ("%s | %s | %s | %s | %s"):format(
                getBotNick(), tostring(settings.password), getBotScore(), current_server, my_proxy_ip
            ))
            sendTG(("Аккаунт успешно прокачен. Ник: %s | Уровень: %s | Сервер: %s"):format(
                getBotNick(), getBotScore(), current_server
            ))
            wait(300)
            if gen_nick then
                setRandomNick()
            else
                exit()
            end
        end
    end)
end

function sampev.onShowTextDraw(id, data)
    if data.selectable and data.text == "selecticon3" and data.position.x == 233.0 and data.position.y == 337.0 then
        newTask(sendClickTextdraw, math.random(2500, 3500), id)
    end
    if data.modelId == 19196 and use_x3 then
        newTask(sendClickTextdraw, math.random(1800, 2600), id)
        use_x3 = false
    end
    if data.text == "USE" or data.text == "ИСПОЛЬЗОВАТЬ" or data.text == "ИCПOЛЬЗOВAТЬ" then
        newTask(sendClickTextdraw, math.random(1800, 2500), id + 1)
    end
end

-- ================= СООБЩЕНИЯ СЕРВЕРА И ЭВРИСТИКА ЧАТА =================

function sampev.onServerMessage(color, text)
    local clean_text = text:gsub("%{......%}", "")
    local lower_text = clean_text:lower()

    -- 1. Эвристический детект проверок от Админа в чате (с обходом цветных тегов)
    if clean_text:find("телепортировал вас на координаты") or clean_text:find("Вы были телепортированы администратором") then
        adminPanic("Админ телепортировал по координатам")
        return
    end
    if clean_text:find("Администратор .+ написал вам:") or clean_text:find("%(%( Администратор")
       or ((lower_text:find("вы тут") or lower_text:find("тут%?") or lower_text:find("вы бот")) and not clean_text:find("%[Семья%]") and not clean_text:find("%[VIP")) then
        adminPanic("Проверка от админа в чате: " .. clean_text)
        return
    end

    -- 2. Голод и чипсы
    if clean_text:find("У вас нет с собой еды") or clean_text:find("У вас нет чипсов") then
        has_chips = false
        eating_chips = false
    end
    if (clean_text:find("Вы проголодались") or clean_text:find("Вы очень голодны")) and has_chips then
        eatChips()
    end

    -- 3. Выпадение X3 ускоренной прокачки
    if clean_text:find("Ускоренная прокачка %(X3%)") and clean_text:find("%/invent") then
        use_x3 = true
        newTask(function()
            wait(math.random(1200, 2500))
            sendInput("/invent")
        end)
    end

    -- 4. Наказания (Варн, Мут, Бан, Деморган)
    if clean_text:find("A%: (.+)%[(%d+)%] выдал предупреждение игроку (.+)%[(%d+)%] %[(%d+)%/(%d+)%] Причина%: (.+)") then
        local admnick, admid, playernick, playerid, warn1, warn2, reason = clean_text:match("A%: (.+)%[(%d+)%] выдал предупреждение игроку (.+)%[(%d+)%] %[(%d+)%/(%d+)%] Причина%: (.+)")
        if playernick == getBotNick() and tonumber(playerid) == getBotId() then
            sendTG(("Выдали варн.\nПричина: %s\nНик: %s\nСервер: %s"):format(reason, getBotNick(), current_server))
        end
    end

    if clean_text:find("A%: (.+)%[(%d+)%] заглушил игрока (.+)%[(%d+)%] на (%d+) минут%. Причина%: (.+)") then
        local admnick, admid, playernick, playerid, time, reason = clean_text:match("A%: (.+)%[(%d+)%] заглушил игрока (.+)%[(%d+)%] на (%d+) минут%. Причина%: (.+)")
        if playernick == getBotNick() and tonumber(playerid) == getBotId() then
            sendTG(("Выдали мут.\nПричина: %s\nНик: %s\nАЙДИ: %s\nСервер: %s"):format(reason, getBotNick(), getBotId(), current_server))
        end
    end

    if clean_text:find("A%: (.+)%[(%d+)%] забанил игрока (.+)%[(%d+)%] на (%d+) дней%. Причина%: (.+)") then
        local admnick, admid, playernick, playerid, time, reason = clean_text:match("A%: (.+)%[(%d+)%] забанил игрока (.+)%[(%d+)%] на (%d+) дней%. Причина%: (.+)")
        if playernick == getBotNick() and tonumber(playerid) == getBotId() then
            writeTxt("termuh\\accounts\\banned.txt", ("%s | %s | %s | %s | %s"):format(
                getBotNick(), tostring(settings.password), getBotScore(), current_server, my_proxy_ip
            ))
            sendTG(("Забанили.\nПричина: %s\nДлительность(дни): %s\nНик: %s\nСервер: %s"):format(reason, time, getBotNick(), current_server))
            if gen_nick then setRandomNick() end
        end
    end

    if clean_text:find("A%: (.+)%[(%d+)%] посадил игрока (.+)%[(%d+)%] в деморган на (%d+) минут%. Причина%: (.+)") then
        local adminnick, adminid, playernick, playerid, time, reason = clean_text:match("A%: (.+)%[(%d+)%] посадил игрока (.+)%[(%d+)%] в деморган на (%d+) минут%. Причина%: (.+)")
        if playernick == getBotNick() and tonumber(playerid) == getBotId() then
            sendTG(("Посадили в дмг.\nПричина: %s\nДлительность(минут): %s\nНик: %s\nАЙДИ: %s\nСервер: %s"):format(reason, time, getBotNick(), getBotId(), current_server))
        end
    end

    if clean_text:find("A%: (.+)%[(%d+)%] забанил игрока (.+)%[(%d+)%]%. Причина%: (.+)") then
        local adminnick, adminid, playernick, playerid, reason = clean_text:match("A%: (.+)%[(%d+)%] забанил игрока (.+)%[(%d+)%]%. Причина%: (.+)")
        if playernick == getBotNick() and tonumber(playerid) == getBotId() then
            writeTxt("termuh\\accounts\\banned.txt", ("%s | %s | %s | %s | %s"):format(
                getBotNick(), tostring(settings.password), getBotScore(), current_server, my_proxy_ip
            ))
            sendTG(("Забанили по ипу.\nПричина: %s\nНик: %s\nСервер: %s"):format(reason, getBotNick(), current_server))
            if settings.proxy then remove_bad_proxy() end
            if gen_nick then setRandomNick() end
        end
    end

    -- 5. PayDay и Повышение уровня
    if clean_text:find("Банковский чек") or clean_text:find("Для получения PayDay вы должны отыграть минимум (%d+) минут") then
        if settings.present_code and tostring(settings.present_code) ~= "" then
            newTask(function()
                wait(math.random(1500, 3500))
                sendInput("/present " .. tostring(settings.present_code))
            end)
        end
    end

    if clean_text:find("Поздравляем%! Вы достигли (%d+)%-го уровня%!") then
        local lvl = clean_text:match("Поздравляем%! Вы достигли (%d+)%-го уровня%!")
        sendTG(("Апнул %s лвл. Ник: %s | Сервер: %s"):format(lvl, getBotNick(), current_server))
        if tonumber(lvl) >= (tonumber(settings.promo_lvl) or 5) then
            newTask(function()
                wait(math.random(1500, 3000))
                sendInput("/mm")
            end)
        end
        if tonumber(lvl) >= (tonumber(settings.up_lvl) or 5) then
            writeTxt("termuh\\accounts\\good.txt", ("%s | %s | %s | %s | %s"):format(
                getBotNick(), tostring(settings.password), lvl, current_server, my_proxy_ip
            ))
            sendTG(("Аккаунт успешно прокачен. Ник: %s | Уровень: %s | Сервер: %s"):format(getBotNick(), lvl, current_server))
            if gen_nick then
                setRandomNick()
            else
                exit()
            end
        end
    end
end

-- ================= СИСТЕМНЫЕ СОБЫТИЯ И КОМАНДЫ КОНСОЛИ =================

function onRequestConnect()
    if gen_nick and getBotNick() == "nick" then return false end
    if not isProxyConnected() and settings.proxy then return false end
end

function onProxyError()
    if my_proxy_ip then
        sendTG("Не работает прокси (удаляю из пула). IP: " .. my_proxy_ip)
    end
    remove_bad_proxy()
end

function onLoad()
    -- 1. Инициализация AimSync Fix
    setRate(AIM_SYNC_RATE, 1000)
    print("[AimSync FIX] Загружен и объединен.")

    -- 2. Инициализация Follow
    setAutoPick(true)
    print("[Follow] Загружен и объединен.")

    -- 3. Инициализация основного бота
    if getBotNick() == "nick" then
        gen_nick = true
        setRandomNick()
    end

    get_server_name(getServerAddress())
    get_refpromo(current_server)
    startHungerTimer()

    if token and chatid then
        getLastUpdate()
        get_telegram_updates()
    end

    if settings.proxy then
        load_proxys("termuh\\proxy.txt")
        connect_random_proxy()
    end
end

function onRunCommand(cmd)
    if cmd == "!newproxy" then
        remove_bad_proxy()
        return false
    elseif cmd == "!gennick" then
        setRandomNick()
        return false
    elseif cmd == "!eat" then
        eatChips()
        return false
    end

    -- Команды модуля Follow
    if cmd:match("^!follow .+") then
        local param = cmd:match("^!follow (.+)")
        if param:match("^%d+") then
            follow.target_Id = tonumber(param:match("^(%d+)"))
            fprint(string.format("Следование запущено за ID %d.", follow.target_Id))
        elseif param:match("^stop") then
            follow.target_Id = -1
            fprint("Следование остановлено.")
        elseif param:match("^bubble") then
            follow.bubble = not follow.bubble
            fprint(string.format("Повтор чата (bubble): %s.", follow.bubble and "ВКЛ" or "ВЫКЛ"))
        elseif param:match("^offset %-?%d+") then
            follow.offset = tonumber(param:match("^offset (%-?%d+)"))
            fprint(string.format("Новое смещение (offset): %d.", follow.offset))
        elseif param:match("^dist %-?%d+") then
            follow.min_dist = tonumber(param:match("^dist (%-?%d+)"))
            fprint(string.format("Новая дистанция (dist): %d.", follow.min_dist))
        end
        return false
    end

    if cmd:match("^!enterveh %d+") then
        local vehId = tonumber(cmd:match("^!enterveh (%d+)"))
        follow.temp_task = newTask(function()
            follow.target_Id = -1
            follow.player_state = state.DRIVER
            sendVehicleEnter(vehId, 0)
            wait(500)
            setBotVehicle(vehId, 0)
            fprint(string.format("Бот сел за руль авто ID %d", vehId))
        end)
        return false
    end

    if cmd:match("^!exitveh") then
        follow.temp_task = newTask(function()
            follow.target_Id = -1
            fprint(string.format("Бот вышел из авто ID %d.", getBotVehicle()))
            sendVehicleExit(getBotVehicle())
            wait(500)
            setBotVehicle(0, 0)
            follow.player_state = state.ONFOOT
        end)
        return false
    end
end

-- ================= TELEGRAM BOT API =================

function threadHandle(runner, url, args, resolve, reject)
    local t = runner(url, args)
    local r = t:get(0)
    while not r do
        r = t:get(0)
        wait(0)
    end
    local status = t:status()
    if status == "completed" then
        local ok, result = r[1], r[2]
        if ok then
            resolve(result)
        else
            reject(result)
        end
    elseif status == "canceled" then
        reject(status)
    end
    t:cancel(0)
end

function requestRunner()
    return effil.thread(function(u, a)
        local https = require("ssl.https")
        local ok, result = pcall(https.request, u, a)
        if ok then
            return {true, result}
        else
            return {false, result}
        end
    end)
end

function async_http_request(url, args, resolve, reject)
    local runner = requestRunner()
    reject = reject or function() end
    newTask(function()
        threadHandle(runner, url, args, resolve, reject)
    end)
end

function encodeUrl(str)
    str = u8:encode(str, "CP1251")
    str = str:gsub("\n", "%%0A")
    str = str:gsub("([^%w%-%.%_%~%/])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

function sendTG(msg)
    if not token or not chatid then return end
    msg = msg:gsub("{......}", "")
    msg = encodeUrl(msg)
    async_http_request("https://api.telegram.org/bot" .. token .. "/sendMessage?chat_id=" .. chatid .. "&text=" .. msg, "", function(result) end)
end

function get_telegram_updates()
    newTask(function()
        while not updateid do
            wait(100)
        end
        local runner = requestRunner()
        local reject = function() end
        local args = ""
        while true do
            local url = "https://api.telegram.org/bot" .. token .. "/getUpdates?chat_id=" .. chatid .. "&offset=-1"
            threadHandle(runner, url, args, processing_telegram_messages, reject)
            wait(3000 + math.random(500, 2500))
        end
    end)
end

local cmds = {
    "/bots - список всех ботов онлайн",
    "/recon (all/id) - перезайти на сервер",
    "/newproxy (all/id) - сменить прокси",
    "/eat (all/id) - съесть чипсы (/eat)",
    "/follow (bot_id) (target_id/stop) - бежать за игроком",
    "/send (id) (текст) - отправить команду/текст в чат",
    "/exit (all/id) - выйти с аккаунта(ов)",
    "/help - список команд",
}

function processing_telegram_messages(result)
    if not result then return end
    local ok, proc_table = pcall(json.decode, result)
    if not ok or not proc_table or not proc_table.ok then return end

    if #proc_table.result > 0 then
        local res_table = proc_table.result[1]
        if res_table and res_table.update_id ~= updateid then
            updateid = res_table.update_id
            local message_from_user = res_table.message and res_table.message.text
            if message_from_user then
                local text = u8:decode(message_from_user)

                if text:find("^%/exit") then
                    local mode = text:match("^%/exit%s+(.+)")
                    if mode then
                        mode = mode:gsub("%s", "")
                        if mode == "all" or tonumber(mode) == getBotId() then
                            sendTG(("Вышел с аккаунта.\nНик: %s\nСервер: %s"):format(getBotNick(), current_server))
                            newTask(exit, 100)
                        end
                    else
                        sendTG("Используй: /exit (all/id)")
                    end

                elseif text:find("^%/recon") then
                    local mode = text:match("^%/recon%s+(.+)")
                    if mode then
                        mode = mode:gsub("%s", "")
                        if mode == "all" or tonumber(mode) == getBotId() then
                            sendTG(("Реконнект бота: %s | Сервер: %s"):format(getBotNick(), current_server))
                            reconnect(2000)
                        end
                    else
                        sendTG("Используй: /recon (all/id)")
                    end

                elseif text:find("^%/newproxy") then
                    local mode = text:match("^%/newproxy%s+(.+)")
                    if mode then
                        mode = mode:gsub("%s", "")
                        if mode == "all" or tonumber(mode) == getBotId() then
                            remove_bad_proxy()
                            sendTG(("Сменил прокси на %s | Бот: %s"):format(tostring(my_proxy_ip), getBotNick()))
                        end
                    else
                        sendTG("Используй: /newproxy (all/id)")
                    end

                elseif text:find("^%/eat") then
                    local mode = text:match("^%/eat%s+(.+)")
                    if mode then
                        mode = mode:gsub("%s", "")
                        if mode == "all" or tonumber(mode) == getBotId() then
                            eatChips()
                            sendTG(("Отправил /eat на боте: %s"):format(getBotNick()))
                        end
                    else
                        sendTG("Используй: /eat (all/id)")
                    end

                elseif text:find("^%/follow") then
                    local bot_id, target = text:match("^%/follow%s+(%d+)%s+(.+)")
                    if bot_id and target and tonumber(bot_id) == getBotId() then
                        target = target:gsub("%s", "")
                        if target == "stop" then
                            follow.target_Id = -1
                            sendTG(("Follow остановлен на боте %s"):format(getBotNick()))
                        elseif tonumber(target) then
                            follow.target_Id = tonumber(target)
                            sendTG(("Бот %s начал движение за игроком ID %d"):format(getBotNick(), follow.target_Id))
                        end
                    end

                elseif text:find("^%/send") then
                    local target_id, cmd_text = text:match("^%/send%s+(%d+)%s+(.+)")
                    if target_id and cmd_text then
                        if tonumber(target_id) == getBotId() then
                            sendInput(cmd_text)
                            sendTG(("Отправлено [%s]: %s"):format(getBotNick(), cmd_text))
                        end
                    else
                        sendTG("Используй: /send (id) (текст или команда)")
                    end

                elseif text:find("^%/bots") then
                    sendTG(("Ник: %s | ID: %s | ЛВЛ: %s | Сервер: %s | Прокси: %s"):format(
                        getBotNick(), getBotId(), getBotScore(), current_server, tostring(my_proxy_ip)
                    ))

                elseif text:find("^%/help") then
                    local str_cmds = table.concat(cmds, "\n")
                    sendTG("Команды бота:\n" .. str_cmds)
                end
            end
        end
    end
end

function getLastUpdate()
    local offset = -1
    async_http_request("https://api.telegram.org/bot" .. token .. "/getUpdates?chat_id=" .. chatid .. "&offset=" .. offset, "", function(result)
        if result then
            local ok, proc_table = pcall(json.decode, result)
            if ok and proc_table and proc_table.ok then
                if #proc_table.result > 0 and proc_table.result[1] then
                    updateid = proc_table.result[1].update_id
                else
                    updateid = offset + 1
                end
            end
        end
    end)
end