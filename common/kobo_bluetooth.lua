local Device = require("device")
local logger = require("common/zen_logger").new("kobo_bluetooth")

local M = {}
local MTK_SERVICE = "com.kobo.mtk.bluedroid"
local ADAPTER = "/org/bluez/hci0"
local PROPERTIES = "org.freedesktop.DBus.Properties"
local owned = false
local pending
local cached_state, cached_at

local function plugin_bluetooth()
    local zen = rawget(_G, "__ZEN_UI_PLUGIN")
    local kobo = zen and zen.ui and zen.ui.kobo_plugin
    local bluetooth = kobo and kobo.kobo_bluetooth
    if bluetooth and bluetooth.isDeviceSupported and bluetooth:isDeviceSupported() then
        return bluetooth
    end
end

local function kind()
    if not (Device.isKobo and Device:isKobo()) then return nil end
    if Device.model == "Kobo_io" then return "libra2" end
    if Device.isMTK and Device:isMTK() then
        local file = io.open("/usr/share/dbus-1/system-services/" .. MTK_SERVICE .. ".service", "r")
        if file then
            file:close()
            return "mtk"
        end
    end
end

local function command_ok(command)
    local ok, _, code = os.execute(command .. " >/dev/null 2>&1")
    return ok == true or ok == 0 or code == 0
end

local function query_bool(command)
    local pipe = io.popen(command .. " 2>/dev/null", "r")
    if not pipe then return nil end
    local output = pipe:read("*a") or ""
    pipe:close()
    if output:find("boolean true", 1, true) then return true end
    if output:find("boolean false", 1, true) then return false end
end

local function destination(device_kind)
    return device_kind == "mtk" and MTK_SERVICE or "org.bluez"
end

local function dbus(device_kind, path, method, args)
    return "dbus-send --system --print-reply --reply-timeout=10000 --dest="
        .. destination(device_kind) .. " " .. path .. " " .. method .. (args or "")
end

local function property(device_kind, value)
    return dbus(device_kind, ADAPTER, PROPERTIES .. "." .. (value == nil and "Get" or "Set"),
        " string:org.bluez.Adapter1 string:Powered"
        .. (value == nil and "" or " variant:boolean:" .. tostring(value)))
end

local function read_state(device_kind)
    local owner = query_bool("dbus-send --system --print-reply --reply-timeout=1500"
        .. " --dest=org.freedesktop.DBus /org/freedesktop/DBus"
        .. " org.freedesktop.DBus.NameHasOwner string:" .. destination(device_kind))
    if owner == false then return false end
    if owner == nil then return nil end
    return query_bool(property(device_kind))
end

local function emit(enabled)
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    UIManager:broadcastEvent(Event:new("BluetoothStateChanged", { state = enabled }))
end

local function power(device_kind, enabled)
    if device_kind == "mtk" then
        if enabled and not command_ok(dbus("mtk", "/", "com.kobo.bluetooth.BluedroidManager1.On")) then
            return false
        end
        if not command_ok(property("mtk", enabled)) then
            if enabled then command_ok(dbus("mtk", "/", "com.kobo.bluetooth.BluedroidManager1.Off")) end
            return false
        end
        return enabled or command_ok(dbus("mtk", "/", "com.kobo.bluetooth.BluedroidManager1.Off"))
    end

    if enabled then
        if not command_ok("grep -q '^sdio_bt_pwr ' /proc/modules"
                .. " || insmod /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko") then return false end
        if not command_ok("pgrep rtk_hciattach >/dev/null"
                .. " || /sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5 >/dev/null 2>&1") then return false end
        if not command_ok("pgrep bluetoothd >/dev/null"
                .. " || ( /libexec/bluetooth/bluetoothd >/dev/null 2>&1 & )") then return false end
        if not command_ok("i=0; while [ $i -lt 50 ] && ! " .. property("libra2")
                .. " >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done") then return false end
        return command_ok(property("libra2", true))
    end

    if not command_ok(property("libra2", false)) then return false end
    return command_ok("killall bluetoothd rtk_hciattach 2>/dev/null; "
        .. "i=0; while [ $i -lt 30 ] && (pgrep bluetoothd >/dev/null"
        .. " || pgrep rtk_hciattach >/dev/null); do sleep 0.1; i=$((i+1)); done; "
        .. "rmmod sdio_bt_pwr 2>/dev/null; true")
end

function M.isAvailable()
    return plugin_bluetooth() ~= nil or kind() ~= nil
end

function M.getState()
    local plugin = plugin_bluetooth()
    if plugin then return plugin:isBluetoothEnabled() end
    local device_kind = kind()
    if not device_kind then return nil end
    local now = os.time()
    if cached_at and now - cached_at < 2 then return cached_state end
    cached_state = read_state(device_kind)
    cached_at = now
    return cached_state
end

function M.setEnabled(enabled, complete)
    local plugin = plugin_bluetooth()
    if plugin then
        if enabled then plugin:turnBluetoothOn(false) else plugin:turnBluetoothOff(false) end
        return true
    end
    local device_kind = kind()
    if not device_kind then return false end
    if pending then return false end
    local state = M.getState()
    if state == nil then return false end
    local UIManager = require("ui/uimanager")
    if state == enabled then
        if not enabled and owned then
            UIManager:allowStandby()
            owned = false
        end
        return true
    end

    local function finish()
        local success = power(device_kind, enabled)
        cached_at = nil
        if success then
            if enabled then
                UIManager:preventStandby()
                owned = true
            elseif owned then
                UIManager:allowStandby()
                owned = false
            end
            emit(enabled)
        else
            logger.warn("Bluetooth power request failed", device_kind, tostring(enabled))
            if not enabled and owned and read_state(device_kind) == false then
                UIManager:allowStandby()
                owned = false
                emit(false)
            end
        end
        if complete then complete(success) end
        return success
    end

    if device_kind == "mtk" and enabled then
        local NetworkMgr = require("ui/network/manager")
        if not NetworkMgr:isWifiOn() then
            NetworkMgr:restoreWifiAsync()
            pending = function()
                pending = nil
                finish()
                NetworkMgr:disableWifi(nil, false)
            end
            UIManager:scheduleIn(1, pending)
            return true
        end
    end
    return finish()
end

function M.onSuspend()
    if pending then
        require("ui/uimanager"):unschedule(pending)
        pending = nil
        require("ui/network/manager"):disableWifi(nil, false)
    end
    if owned then
        cached_at = nil
        M.setEnabled(false)
    end
end

return M
