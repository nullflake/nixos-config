--!nonstrict
local records = require("./records.luau")
local Module = {}

function Module.new(dataDir)
    local M = {}
    local validId = records.validId
    local validRecords, contains, without, record = records.validRecords, records.contains, records.without, records.record
    local libraryPath = dataDir and (dataDir .. "/library.json") or nil
    M.data = {version = 1, later = {}, history = {}, favorites = {}, channelPlays = {}}
    M.error = nil
    local HISTORY_LIMIT = 500
    local function validPlays(plays)
        if type(plays) ~= "table" then return false end
        for id, count in pairs(plays) do
            if not validId(id, true) or type(count) ~= "number" or count < 0
                or count >= math.huge or count % 1 ~= 0 then return false end
        end
        return true
    end
    local function validQueueEvents(events)
        if type(events) ~= "table" then return false end
        for id, token in pairs(events) do
            if not validId(id, false) or type(token) ~= "string" then return false end
        end
        return true
    end
    if libraryPath and noctalia.fileExists(libraryPath) then
        local body = noctalia.readFile(libraryPath)
        local ok, saved = pcall(noctalia.json.decode, body or "")
        if ok and type(saved) == "table" and saved.version == 1
            and validRecords(saved.later) and validRecords(saved.history)
            and (saved.favorites == nil or validRecords(saved.favorites, true))
            and (saved.channelPlays == nil or validPlays(saved.channelPlays))
            and (saved.queueEvents == nil or validQueueEvents(saved.queueEvents)) then
            -- Existing libraries acquire favorites without rewriting their video records.
            saved.favorites = saved.favorites or {}
            saved.channelPlays = saved.channelPlays or {}
            M.data = saved
        else
            -- Preserve unreadable or incompatible data instead of overwriting it.
            M.error = "Could not read the YouTube library; existing data was preserved"
        end
    end
    local function saveLibrary(later, history, favorites, channelPlays, queueEvents)
        if M.error then noctalia.notifyError(M.error); return false end
        if not libraryPath or not noctalia.mkdirAll(dataDir) then
            noctalia.notifyError("YouTube library storage is unavailable"); return false
        end
        local updated = {version = 1, later = later, history = history, favorites = favorites or M.data.favorites,
            channelPlays = channelPlays or M.data.channelPlays,
            queueEvents = queueEvents or M.data.queueEvents or {}}
        local ok, body = pcall(noctalia.json.encode, updated)
        local temporary = libraryPath .. ".part"
        if ok and type(body) == "string" and noctalia.writeFile(temporary, body)
            and noctalia.renameFile(temporary, libraryPath) then
            M.data = updated
            return true
        end
        noctalia.removeFile(temporary)
        noctalia.notifyError("Could not save the YouTube library")
        return false
    end
    local function sortedFavorites()
        local favorites = {}
        for _, item in ipairs(M.data.favorites) do table.insert(favorites, item) end
        table.sort(favorites, function(a, b)
            local ac, bc = M.data.channelPlays[a.id] or 0, M.data.channelPlays[b.id] or 0
            if ac ~= bc then return ac > bc end
            if a.title ~= b.title then return a.title < b.title end
            return a.id < b.id
        end)
        return favorites
    end
    local function rememberPlayed(item, eventToken)
        if not item then return end
        if eventToken and M.data.queueEvents and M.data.queueEvents[item.id] == eventToken then return true end
        local history = without(M.data.history, item.id)
        table.insert(history, 1, record(item))
        while #history > HISTORY_LIMIT do table.remove(history) end
        local plays = {}
        for id, count in pairs(M.data.channelPlays) do plays[id] = count end
        if item.channelId then plays[item.channelId] = (plays[item.channelId] or 0) + 1 end
        local later = {}
        for _, known in ipairs(M.data.later) do
            table.insert(later, known.id == item.id and record(item) or known)
        end
        local events = {}
        for id, token in pairs(M.data.queueEvents or {}) do events[id] = token end
        if eventToken then events[item.id] = eventToken end
        -- Keep receipts only for retained history entries so they cannot grow without bound.
        for id in pairs(events) do if not contains(history, id) then events[id] = nil end end
        return saveLibrary(later, history, nil, plays, events)
    end

    M.save, M.sortedFavorites, M.rememberPlayed = saveLibrary, sortedFavorites, rememberPlayed
    return M
end

return Module
