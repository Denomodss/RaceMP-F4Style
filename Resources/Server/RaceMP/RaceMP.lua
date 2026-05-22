-- RaceMP (Server) by Dudekahedron and Funky7Monkey 2023
-- + Formation Lap, Essais Libres, Qualifications

local settings        = {}
local players         = {}
local formationActive = false
local sessionMode     = "race"   -- "race" | "el" | "qualifs"
local qualifEndTime   = nil      -- timestamp os.time() de fin de qualifs
local qualifDuration  = 15 * 60  -- défaut 15 min en secondes

local function prettyTime(seconds)
    local thousandths = seconds * 1000
    local mm = math.floor((thousandths / (60 * 1000))) % 60
    local ss = math.floor(thousandths / 1000) % 60
    local ms = math.floor(thousandths % 1000)
    return string.format("%02d:%02d.%d", mm, ss, ms)
end

local function tableLength(t)
    local counter = 0
    for k,v in pairs(t) do counter = counter + 1 end
    return counter
end

function splitPosition(player, pTable, lap)
    player = tonumber(player)
    local lastLap   = #pTable[player]
    local lastSplit = #pTable[player][lastLap]
    local position  = 1

    if lap then
        for p, laps in pairs(pTable) do
            if players[p][lastLap] then position = position + 1 end
            pTable[player][lastLap]['position'] = position
        end
    else
        for p, laps in pairs(pTable) do
            if pTable[p][lastLap] then
                if pTable[p][lastLap][lastSplit] then position = position + 1 end
            end
            pTable[player][lastLap][lastSplit]['position'] = position
        end
    end
    return pTable
end

function addCurrentPostition(pTable)
    local location = {}
    for id, player in pairs(pTable) do
        local total   = player['splits']
        local lastLap = #player
        local dec     = 0

        if not player[lastLap] then goto continue end
        if next(player[lastLap]) == nil then lastLap = lastLap - 1 end
        if lastLap < 1 then goto continue end

        local lastSplit = tableLength(player[lastLap])

        if player[lastLap]['position'] then
            total = total - 1
            dec   = player[lastLap]['position'] / 100
        else
            if not player[lastLap][lastSplit] then goto continue end
            dec = player[lastLap][lastSplit]['position'] / 100
        end

        total = total - dec
        table.insert(location, {['total'] = total, ['player'] = id})
        ::continue::
    end

    if #location > 1 then
        table.sort(location, function(k1, k2)
            if k1.total and k2.total then return k1.total > k2.total
            elseif k2.total then return false
            else return true end
        end)
    end

    for position, t in pairs(location) do
        pTable[t['player']]['position'] = position
    end

    print(Util.JsonEncode(pTable))
    return pTable
end

-- Classement EL/Qualifs : trié par best lap uniquement
local function addBestLapPosition(pTable)
    local ranking = {}
    for id, player in pairs(pTable) do
        local best = nil
        for k, v in pairs(player) do
            if type(k) == "number" and type(v) == "table" and v['lapTime'] then
                if best == nil or v['lapTime'] < best then best = v['lapTime'] end
            end
        end
        if best then
            table.insert(ranking, { player = id, best = best })
        end
    end
    table.sort(ranking, function(a, b) return a.best < b.best end)
    for pos, entry in ipairs(ranking) do
        pTable[entry.player]['position'] = pos
    end
    return pTable
end

local function raceEnd(player, position)
    print(MP.GetPlayerName(player) .. " finished")
    MP.SendChatMessage(-1, MP.GetPlayerName(player) .. " finished")
    local send = {
        ['trigger']     = 'ChangeState',
        ['state']       = 'scenario-start',
        ['title']       = "Race Finished",
        ['buttonText']  = "Okay",
        ['description'] = string.format("Congratulations\nYou finished in position %s", tostring(position))
    }
    MP.TriggerClientEvent(player, "RaceMPMessage", Util.JsonEncode(send))
end

-- Notifie tous les clients du mode et état de session
local function broadcastSession()
    local remaining = nil
    if sessionMode == "qualifs" and qualifEndTime then
        remaining = math.max(0, qualifEndTime - os.time())
    end
    local send = Util.JsonEncode({
        ['trigger']      = 'sessionUpdate',
        ['mode']         = sessionMode,
        ['remaining']    = remaining,
        ['duration']     = qualifDuration,
    })
    MP.TriggerClientEvent(-1, "RaceMPSession", send)
end

function lapStop(player, data)
    player = tonumber(player)
    data   = Util.JsonDecode(data)
    players[player][#players[player]]['lapTime'] = data['lapTime']
    players[player][#players[player]]['penalty'] = data['penalty']
    players[player][#players[player]]['position'] = data['position']
    players[player]['splits'] = players[player]['splits'] + 1

    local penalty = (data["penalty"] > 0) and " Penalty" or ""
    MP.SendChatMessage(-1, MP.GetPlayerName(player) .. ": " .. prettyTime(data["lapTime"]) .. penalty)

    if sessionMode == "race" then
        players = splitPosition(player, players, true)
        players = addCurrentPostition(players)
        if settings["lapCount"] and #players[player] == settings["lapCount"] then
            raceEnd(player, players[player]['position'])
        end
    else
        -- EL et Qualifs : classement par best lap
        players = addBestLapPosition(players)
    end

    MP.TriggerClientEvent(-1, "clientRaceboardData", Util.JsonEncode(players))
end

function onChatMessage(senderID, name, message)

    -- /el : Essais Libres
    if message == "/el" then
        sessionMode   = "el"
        qualifEndTime = nil
        resetLaps()
        local send = Util.JsonEncode({ ['trigger'] = 'sessionUpdate', ['mode'] = 'el', ['remaining'] = nil })
        MP.TriggerClientEvent(-1, "RaceMPSession", send)
        MP.SendChatMessage(-1, "[RaceMP] Essais Libres démarrés — chrono libre, pas de limite de tours.")
        return 1

    -- /qualifs [minutes]
    elseif string.sub(message, 1, 8) == "/qualifs" then
        local mins = tonumber(string.match(message, "/qualifs%s+(%d+)")) or 15
        qualifDuration = mins * 60
        qualifEndTime  = os.time() + qualifDuration
        sessionMode    = "qualifs"
        resetLaps()
        local send = Util.JsonEncode({
            ['trigger']   = 'sessionUpdate',
            ['mode']      = 'qualifs',
            ['remaining'] = qualifDuration,
            ['duration']  = qualifDuration,
        })
        MP.TriggerClientEvent(-1, "RaceMPSession", send)
        MP.SendChatMessage(-1, string.format("[RaceMP] Qualifications démarrées — %d minutes.", mins))
        -- Lancer le timer en tâche de fond
        MP.TriggerGlobalEvent("onQualifTimer")
        return 1

    -- /formation
    elseif message == "/formation" then
        formationActive = true
        MP.TriggerClientEvent(-1, "RaceMPFormation", Util.JsonEncode({ ['trigger'] = 'formationStart' }))
        MP.SendChatMessage(-1, "[RaceMP] Formation lap activé")
        return 1

    -- /start : course normale
    elseif message == "/start" then
        sessionMode   = "race"
        qualifEndTime = nil
        -- Terminer formation si active
        if formationActive then
            formationActive = false
            MP.TriggerClientEvent(-1, "RaceMPFormation", Util.JsonEncode({ ['trigger'] = 'formationEnd' }))
            MP.Sleep(300)
        end
        -- Terminer EL/Qualifs si actives
        MP.TriggerClientEvent(-1, "RaceMPSession", Util.JsonEncode({ ['trigger'] = 'sessionUpdate', ['mode'] = 'race', ['remaining'] = nil }))
        MP.SendChatMessage(-1, "Race is about to start!")
        MP.TriggerGlobalEvent("onCountdown")
        return 1

    elseif message == "/list" then
        MP.TriggerClientEvent(senderID, "ListRaces", "")
        return 1

    elseif string.find(message, "/set") then
        local args = {}
        for k, v in string.gmatch(message, "(%w+)=([%w_]+)") do args[k] = v end
        -- Merger seulement les valeurs présentes, ne pas écraser les autres
        if args["laps"]       then settings["lapCount"] = tonumber(args["laps"]) end
        if args["track"]      then settings["track"]    = args["track"] end
        if args["raceName"]   then settings["raceName"] = args["raceName"] end
        MP.TriggerClientEvent(-1, "ConfigRace", Util.JsonEncode(settings))
        MP.SendChatMessage(senderID, string.format("[RaceMP] Config: laps=%s track=%s name=%s",
            tostring(settings["lapCount"]), tostring(settings["track"]), tostring(settings["raceName"])))
        return 1
    end
end

function resetLaps()
    for player, _ in pairs(players) do
        players[player] = { ['name'] = MP.GetPlayerName(player), ['splits'] = 0 }
    end
end

function lapStart(player, data)
    player = tonumber(player)
    players[player][#players[player] + 1] = {}
end

function countdown()
    resetLaps()
    local length = 5
    for i = 0, length do
        if i < length then MP.SendChatMessage(-1, "Race Starts in " .. (length - i))
        else               MP.SendChatMessage(-1, "Go!") end
        MP.Sleep(1000)
    end
end

-- Timer qualifs : tourne côté serveur, envoie le remaining toutes les secondes
function qualifTimer()
    while sessionMode == "qualifs" and qualifEndTime do
        local remaining = qualifEndTime - os.time()
        if remaining <= 0 then
            sessionMode   = "race"
            qualifEndTime = nil
            MP.TriggerClientEvent(-1, "RaceMPSession", Util.JsonEncode({
                ['trigger']   = 'sessionUpdate',
                ['mode']      = 'qualifEnd',
                ['remaining'] = 0,
            }))
            MP.SendChatMessage(-1, "[RaceMP] Qualifications terminées !")
            break
        end
        MP.TriggerClientEvent(-1, "RaceMPSession", Util.JsonEncode({
            ['trigger']   = 'sessionUpdate',
            ['mode']      = 'qualifs',
            ['remaining'] = remaining,
            ['duration']  = qualifDuration,
        }))
        MP.Sleep(1000)
    end
end

function onLapSplit(player, data)
    player = tonumber(player)
    data   = Util.JsonDecode(data)
    local lastLap   = #players[player]
    local lastSplit = #players[player][lastLap] + 1
    players[player]['splits'] = players[player]['splits'] + 1
    players[player][lastLap][lastSplit] = data

    if sessionMode == "race" then
        players = splitPosition(player, players, false)
        players = addCurrentPostition(players)
    else
        players = addBestLapPosition(players)
    end
    MP.TriggerClientEvent(-1, "clientRaceboardData", Util.JsonEncode(players))
end

function clientRaceMPLoaded(player)
    print(MP.GetPlayerName(player) .. ": RaceMP loaded")
    player = tonumber(player)
    MP.TriggerClientEvent(player, "ConfigRace", Util.JsonEncode(settings))
    players[player] = { ['name'] = MP.GetPlayerName(player), ['splits'] = 0 }

    if formationActive then
        MP.TriggerClientEvent(player, "RaceMPFormation", Util.JsonEncode({ ['trigger'] = 'formationStart' }))
    end

    -- Envoyer le mode de session actuel au nouveau joueur
    local remaining = nil
    if sessionMode == "qualifs" and qualifEndTime then
        remaining = math.max(0, qualifEndTime - os.time())
    end
    MP.TriggerClientEvent(player, "RaceMPSession", Util.JsonEncode({
        ['trigger']   = 'sessionUpdate',
        ['mode']      = sessionMode,
        ['remaining'] = remaining,
        ['duration']  = qualifDuration,
    }))
end

print("RaceMP + Formation + EL + Qualifs loaded")

MP.RegisterEvent("onLapStart",        "lapStart")
MP.RegisterEvent("onLapStop",         "lapStop")
MP.RegisterEvent("onChatMessage",     "onChatMessage")
MP.RegisterEvent("onCountdown",       "countdown")
MP.RegisterEvent("onQualifTimer",     "qualifTimer")
MP.RegisterEvent("clientRaceMPReady", "clientRaceMPLoaded")
MP.RegisterEvent("onPlayerJoin",      "clientRaceMPLoaded")
MP.RegisterEvent("onLapSplit",        "onLapSplit")
