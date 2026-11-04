--!nonstrict
local records = require("./records.luau")
local Module = {}

function Module.new()
    local M = {}
    local clean, validId, duration = records.clean, records.validId, records.duration
    local without = records.without
    local DEFAULT_INSTANCE = "https://yt.chocolatemoo53.com"
    local INSTANCE = noctalia.getConfig("instance_url")
    local REGION = noctalia.getConfig("region")
    INSTANCE = type(INSTANCE) == "string" and INSTANCE:match("^%s*(.-)%s*$"):gsub("/+$", "") or ""
    -- Accept an HTTP(S) origin, optionally with a port, without credentials or paths.
    local authority = INSTANCE:match("^https?://([^/]+)$")
    local host = authority and (authority:match("^([A-Za-z0-9.-]+):%d+$")
        or authority:match("^([A-Za-z0-9.-]+)$"))
    if not host or not host:match("^[A-Za-z0-9]") or not host:match("[A-Za-z0-9]$") then
        noctalia.notifyError("Invalid Invidious server URL; using the default server")
        INSTANCE = DEFAULT_INSTANCE
    end
    REGION = type(REGION) == "string" and REGION:match("^%s*(.-)%s*$"):upper() or ""
    if not REGION:match("^[A-Z][A-Z]$") then
        noctalia.notifyError("Search region must be a two-letter country code; using US")
        REGION = "US"
    end
    --[[
    This instance redirects images to wsrv.nl. Address that approved proxy directly
    instead of allowing arbitrary redirects that could connect this device to Google.
    ]]
    local function proxyImage(url)
        return "https://wsrv.nl/?url=" .. noctalia.string.urlEncode(url) .. "&maxage=300&output=jpg"
    end
    local function avatarUrl(thumbnails)
        if type(thumbnails) ~= "table" then return nil end
        for _, image in ipairs(thumbnails) do
            local url = type(image) == "table" and image.url or nil
            if type(url) == "string" then
                local prefix = INSTANCE .. "/ggpht/"
                local path = url:sub(1, #prefix) == prefix and url:sub(#prefix + 1)
                    or url:match("^/ggpht/(.+)$")
                if not path then
                    path = url:match("^https?://yt3%.ggpht%.com/(.+)$")
                        or url:match("^//yt3%.ggpht%.com/(.+)$")
                end
                if path and path ~= "" then return proxyImage("https://yt3.ggpht.com/" .. path) end
                path = url:match("^https?://yt3%.googleusercontent%.com/(.+)$")
                    or url:match("^//yt3%.googleusercontent%.com/(.+)$")
                if path then return proxyImage("https://yt3.googleusercontent.com/" .. path) end
            end
        end
        return nil
    end
    local function normalize(source, page)
        local items, seen = {}, {}
        for _, item in ipairs(source) do
            if type(item) == "table" then
                if item.type == "channel" and validId(item.authorId, true) then
                    local key = "channel-" .. item.authorId
                    if not seen[key] then
                        seen[key] = true
                        local name = clean(item.author)
                        if name == "" then name = item.authorId end
                        table.insert(items, {
                            key = key, title = name, subtitle = "Channel · Browse videos", glyph = "user-circle",
                            image = avatarUrl(item.authorThumbnails),
                            destination = {kind = "channel", id = item.authorId, name = name, number = 1, origin = page},
                        })
                    end
                elseif validId(item.videoId, false) then
                    local key = "video-" .. item.videoId
                    if not seen[key] then
                        seen[key] = true
                        local details, title = {"Video"}, clean(item.title)
                        local author, length = clean(item.author), duration(item.lengthSeconds)
                        if author ~= "" then table.insert(details, author) end
                        if length then table.insert(details, length) end
                        if item.liveNow then table.insert(details, "LIVE") end
                        table.insert(items, {
                            key = key, id = item.videoId, title = title ~= "" and title or "Untitled video",
                            channelId = validId(item.authorId, true) and item.authorId
                                or ((page.kind == "channel" or page.kind == "channel-search") and page.id or nil),
                            subtitle = table.concat(details, " · "), glyph = "player-play",
                            image = proxyImage("https://img.youtube.com/vi/" .. item.videoId .. "/hqdefault.jpg"),
                        })
                    end
                end
            end
        end
        return items
    end
    function M.request(page, callback)
        local url
        if page.kind == "channel-search" then
            url = INSTANCE .. "/api/v1/channels/" .. page.id .. "/search?q="
                .. noctalia.string.urlEncode(page.text) .. "&page=" .. page.number
        elseif page.kind == "channel" then
            url = INSTANCE .. "/api/v1/channels/" .. page.id .. "/videos?sort_by=newest"
            if page.continuation then url = url .. "&continuation=" .. noctalia.string.urlEncode(page.continuation) end
        else
            url = INSTANCE .. "/api/v1/search?type=all&q=" .. noctalia.string.urlEncode(page.text)
                .. "&page=" .. page.number .. "&region=" .. REGION
        end
        return noctalia.http({url = url, headers = {"Accept: application/json"}, follow_redirects = false}, callback)
    end
    function M.channelVideos(id, callback)
        return noctalia.http({url = INSTANCE .. "/api/v1/channels/" .. id .. "/videos?sort_by=newest",
            headers = {"Accept: application/json"}, follow_redirects = false}, callback)
    end

    M.instance, M.normalize = INSTANCE, normalize
    return M
end

return Module
