--!nonstrict
local M = {}
local function clean(value)
    return type(value) == "string" and value:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end
local function validId(id, channel)
    return type(id) == "string" and #id == (channel and 24 or 11)
        and (not channel or id:sub(1, 2) == "UC") and id:match("^[A-Za-z0-9_-]+$") ~= nil
end
local function duration(seconds)
    if type(seconds) ~= "number" or seconds < 0 then return nil end
    seconds = math.floor(seconds)
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end
local function validRecords(records, channel)
    if type(records) ~= "table" then return false end
    local seen, count = {}, 0
    for index, item in pairs(records) do
        if type(index) ~= "number" or index < 1 or index > #records or index % 1 ~= 0 or type(item) ~= "table"
            or not validId(item.id, channel) or type(item.title) ~= "string"
            or (item.channelId ~= nil and not validId(item.channelId, true))
            or type(item.subtitle) ~= "string" or seen[item.id] then return false end
        seen[item.id], count = true, count + 1
    end
    return count == #records
end
local function contains(records, id)
    for _, item in ipairs(records) do if item.id == id then return true end end
    return false
end
local function without(records, id)
    local result = {}
    for _, item in ipairs(records) do if item.id ~= id then table.insert(result, item) end end
    return result
end
local function record(item)
    return {id = item.id, title = item.title, subtitle = item.subtitle, channelId = item.channelId}
end

local function enrich(item, sources)
    local result = record(item)
    local function genericTitle(title)
        return title == "" or title == result.id or title == "YouTube · " .. result.id or title == "Untitled video"
    end
    local function genericSubtitle(subtitle)
        return subtitle == "" or subtitle == "Video" or subtitle == "Added from URL"
    end
    for _, records in ipairs(sources) do
        for _, known in ipairs(records) do
            if known.id == result.id then
                if genericTitle(result.title) and not genericTitle(known.title) then result.title = known.title end
                if genericSubtitle(result.subtitle) and not genericSubtitle(known.subtitle) then
                    result.subtitle = known.subtitle
                end
                result.channelId = result.channelId or known.channelId
            end
        end
    end
    return result
end
M.enrich = enrich
M.clean = clean
M.validId = validId
M.duration = duration
M.validRecords = validRecords
M.contains = contains
M.without = without
M.record = record
return M
