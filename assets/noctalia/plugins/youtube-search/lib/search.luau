--!nonstrict
-- YouTube discovery via yt-dlp.
local records = require("./records.luau")
local Module = {}

function Module.new()
    local M = {}
    local clean, validId, duration = records.clean, records.validId, records.duration
    local language = noctalia.getConfig("search_language")
    local languages = {tr = true, en = true, de = true, fr = true, es = true, ru = true, ar = true, ja = true}
    if not languages[language or ""] then language = "tr" end
    local PAGE_SIZE = 20
    local busy, pending = false, nil
    -- Keep the existing image proxy and thumbnail cache when changing search providers.
    local function proxyImage(url)
        return "https://wsrv.nl/?url=" .. noctalia.string.urlEncode(url) .. "&maxage=300&output=jpg"
    end
    local function avatarUrl(thumbnails)
        if type(thumbnails) ~= "table" then return nil end
        for _, image in ipairs(thumbnails) do
            local url = type(image) == "table" and image.url or nil
            if type(url) == "string" then
                local path = url:match("^https?://yt3%.ggpht%.com/(.+)$")
                    or url:match("^//yt3%.ggpht%.com/(.+)$")
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
                if validId(item.id, true) then
                    local key = "channel-" .. item.id
                    if not seen[key] then
                        seen[key] = true
                        local name = clean(item.channel or item.title)
                        if name == "" then name = item.id end
                        table.insert(items, {
                            key = key, title = name, subtitle = "Channel · Browse videos", glyph = "user-circle",
                            image = avatarUrl(item.thumbnails),
                            destination = {kind = "channel", id = item.id, name = name, number = 1, origin = page},
                        })
                    end
                elseif validId(item.id, false) then
                    local key = "video-" .. item.id
                    if not seen[key] then
                        seen[key] = true
                        local details, title = {"Video"}, clean(item.title)
                        local author, length = clean(item.channel or item.uploader), duration(item.duration)
                        if author ~= "" then table.insert(details, author) end
                        if length then table.insert(details, length) end
                        if item.live_status == "is_live" then table.insert(details, "LIVE") end
                        table.insert(items, {
                            key = key, id = item.id, title = title ~= "" and title or "Untitled video",
                            channelId = validId(item.channel_id, true) and item.channel_id
                                or ((page.kind == "channel" or page.kind == "channel-search") and page.id or nil),
                            subtitle = table.concat(details, " · "), glyph = "player-play",
                            image = proxyImage("https://img.youtube.com/vi/" .. item.id .. "/hqdefault.jpg"),
                        })
                    end
                end
            end
        end
        return items
    end
    function M.request(page, callback, limit)
        limit = limit or PAGE_SIZE
        local url
        if page.kind == "channel-search" then
            url = "https://www.youtube.com/channel/" .. page.id .. "/search?query="
                .. noctalia.string.urlEncode(page.text)
        elseif page.kind == "channel" then
            url = "https://www.youtube.com/channel/" .. page.id .. "/videos"
        else
            -- Search URLs retain channel results; ytsearch filters them out.
            url = "https://www.youtube.com/results?search_query=" .. noctalia.string.urlEncode(page.text)
        end
        local function start()
            busy = true
            local function complete(result)
                busy = false
                callback(result)
                if not busy and pending then
                    local nextRequest = pending
                    pending = nil
                    nextRequest()
                end
            end
            if not noctalia.commandExists("yt-dlp") then
                complete({error = "Search requires yt-dlp on PATH"}); return
            end
            -- One extra entry tells us whether another page exists, without loading the entire channel.
            local first = (page.number - 1) * limit + 1
            local args = {"yt-dlp", "--ignore-config", "--no-cache-dir", "--no-warnings", "--force-ipv4",
                "--extractor-args", "youtube:lang=" .. language,
                "--flat-playlist", "--dump-single-json", "--socket-timeout", "8",
                "--retries", "1", "--extractor-retries", "1",
                "--playlist-items", first .. ":" .. (first + limit), "--", url}
            local started = noctalia.runAsync(args, function(result)
                if result.timedOut then complete({error = "YouTube search timed out · Retry"}); return end
                if result.stdoutTruncated then complete({error = "yt-dlp response exceeded the output limit"}); return end
                if result.exitCode ~= 0 then
                    complete({error = "YouTube search failed · " .. clean(result.stderr):sub(1, 240)}); return
                end
                local ok, data = pcall(noctalia.json.decode, result.stdout or "")
                local source = ok and type(data) == "table" and data.entries
                if type(source) ~= "table" or (next(source) ~= nil and source[1] == nil) then
                    complete({error = "Invalid yt-dlp response"}); return
                end
                local hasMore = #source > limit
                source[limit + 1] = nil
                complete({items = normalize(source, page), hasMore = hasMore})
            end, 20000)
            if not started then complete({error = "Could not start yt-dlp · Retry"}) end
        end
        -- Coalesce typing while a process is running; only the latest waiting query is started.
        if busy then pending = start else start() end
    end
    function M.channelVideos(id, callback)
        M.request({kind = "channel", id = id, number = 1}, callback, 3)
    end
    function M.cancel() pending = nil end
    return M
end

return Module
