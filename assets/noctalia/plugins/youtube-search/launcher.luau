--!nonstrict
local browser = (function()
    --[[
    Search uses Invidious and thumbnails use its approved wsrv.nl proxy.
    Playback keeps the shared mpv profile and streams directly from YouTube/Googlevideo.
    ]]
    local M = {}
    local INSTANCE = "https://yt.chocolatemoo53.com"
    local REGION = "TR"
    local generation, currentQuery = 0, ""
    local currentPage = nil
    local routes, allowed, downloading = {}, {}, {}
    local thumbnailQueue, queueIndex, activeDownloads = {}, 1, 0
    --[[
    Noctalia shares eight HTTP slots between searches and image downloads.
    Three image workers leave capacity for normal searches and channel navigation.
    ]]
    local MAX_DOWNLOADS = 3
    -- Reuse pages for back navigation, but let long-running sessions see new uploads.
    local PAGE_TTL_MS = 60000
    local MAX_IMAGE_BYTES = 1024 * 1024
    local dataDir = noctalia.pluginDataDir()
    local cacheDir = dataDir and (dataDir .. "/thumbnails") or nil
    if cacheDir and not noctalia.mkdirAll(cacheDir) then cacheDir = nil end

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
    local function route(page)
        if not page.label then
            local label = page.kind == "channel" and (page.name .. " · Videos · Page " .. page.number)
                or (page.number == 1 and page.text or (page.text .. " · Search page " .. page.number))
            local base, suffix = label, 1
            while routes[label] and routes[label] ~= page do
                suffix = suffix + 1
                label = base .. " (" .. suffix .. ")"
            end
            page.label, routes[label] = label, page
        end
        -- Noctalia prepends the provider prefix to result.query itself.
        return "Search " .. page.label
    end
    local function navigation(title, page, glyph)
        return {id = "navigation:" .. title, title = title, glyph = glyph or "arrow-left", query = route(page)}
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
                            subtitle = table.concat(details, " · "), glyph = "player-play",
                            image = proxyImage("https://img.youtube.com/vi/" .. item.videoId .. "/hqdefault.jpg"),
                        })
                    end
                end
            end
        end
        return items
    end
    local function render()
        local page = currentPage
        if not page then return end
        local rows = {}
        allowed = {}
        if page.error then
            table.insert(rows, {id = "status", title = page.error, subtitle = INSTANCE, glyph = "alert-circle"})
        elseif not page.items or #page.items == 0 then
            table.insert(rows, {id = "status", title = "No results found", glyph = "search"})
        end
        for _, item in ipairs(page.items or {}) do
            local path = cacheDir and (cacheDir .. "/" .. item.key .. ".jpg") or nil
            local icon = path and noctalia.fileExists(path) and path or nil
            local row = {id = item.key, title = item.title, subtitle = item.subtitle, icon = icon,
                glyph = not icon and item.glyph or nil}
            if item.destination then row.query = route(item.destination)
            else allowed[item.key] = item.id end
            table.insert(rows, row)
        end
        if page.next then table.insert(rows, navigation("Next page →", page.next, "arrow-right")) end
        if page.previous then table.insert(rows, navigation("← Previous page", page.previous)) end
        if page.origin then table.insert(rows, navigation("← Back to search", page.origin)) end
        table.insert(rows, {id = "refresh", title = page.error and "Retry" or "Refresh", glyph = "refresh"})
        table.insert(rows, {id = "home", title = "← YouTube", glyph = "arrow-left", query = ""})
        launcher.setResults(currentQuery, rows)
    end
    local function saveThumbnail(path, response)
        local body = response.body
        if not response.ok or response.status ~= 200 or type(body) ~= "string"
            or #body < 12 or #body > MAX_IMAGE_BYTES then return false end
        local jpeg = body:sub(1, 3) == string.char(255, 216, 255)
        local png = body:sub(1, 8) == "\137PNG\r\n\26\n"
        local webp = body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP"
        if not jpeg and not png and not webp then return false end
        local temporary = path .. ".part"
        if noctalia.writeFile(temporary, body) and noctalia.renameFile(temporary, path) then return true end
        noctalia.removeFile(temporary)
        return false
    end
    local pumpThumbnails
    pumpThumbnails = function()
        while activeDownloads < MAX_DOWNLOADS and queueIndex <= #thumbnailQueue do
            local job = thumbnailQueue[queueIndex]
            queueIndex = queueIndex + 1
            if not noctalia.fileExists(job.path) and not downloading[job.key] then
                downloading[job.key] = true
                activeDownloads = activeDownloads + 1
                -- Keep redirects disabled even on the approved image proxy.
                local started = noctalia.http({url = job.url, follow_redirects = false}, function(response)
                    downloading[job.key] = nil
                    activeDownloads = activeDownloads - 1
                    local ok = saveThumbnail(job.path, response)
                    if ok and currentPage and currentPage.items then render() end
                    pumpThumbnails()
                end)
                if not started then
                    downloading[job.key] = nil
                    activeDownloads = activeDownloads - 1
                    -- Keep rejected work queued until an accepted download frees a slot.
                    queueIndex = queueIndex - 1
                    break
                end
            end
        end
    end
    local function requestThumbnails()
        thumbnailQueue, queueIndex = {}, 1
        if not cacheDir or not currentPage then return end
        for _, item in ipairs(currentPage.items or {}) do
            local path = cacheDir .. "/" .. item.key .. ".jpg"
            if item.image and not noctalia.fileExists(path) and not downloading[item.key] then
                table.insert(thumbnailQueue, {key = item.key, url = item.image, path = path})
            end
        end
        pumpThumbnails()
    end
    function M.query(query)
        generation = generation + 1
        local requestGeneration = generation
        currentQuery, currentPage, allowed = query, nil, {}
        thumbnailQueue, queueIndex = {}, 1
        local text = clean(query)
        if text == "Search" then text = "" else text = text:match("^Search%s+(.+)$") or text end
        if text == "" then
            launcher.setResults(query, {
                {id = "hint", title = "Search videos and channels", glyph = "search"},
                {id = "home", title = "← YouTube", glyph = "arrow-left", query = ""},
            })
            return
        end
        local page = routes[text] or {kind = "search", text = text, number = 1}
        route(page)
        currentPage = page
        local age = page.loadedAt and (noctalia.nowMs() - page.loadedAt) or nil
        if page.items and not page.error and age and age >= 0 and age < PAGE_TTL_MS then
            render(); requestThumbnails(); return
        end
        page.items, page.next = nil, nil
        launcher.setResults(query, {{id = "status", title = "Loading…", subtitle = page.name or page.text, glyph = "loader"}})
        local url
        if page.kind == "channel" then
            url = INSTANCE .. "/api/v1/channels/" .. page.id .. "/videos?sort_by=newest"
            if page.continuation then url = url .. "&continuation=" .. noctalia.string.urlEncode(page.continuation) end
        else
            url = INSTANCE .. "/api/v1/search?type=all&q=" .. noctalia.string.urlEncode(page.text)
                .. "&page=" .. page.number .. "&region=" .. REGION
        end
        local started = noctalia.http({url = url, headers = {"Accept: application/json"}, follow_redirects = false}, function(response)
            -- Even stale API callbacks release a shared HTTP slot needed by the image queue.
            pumpThumbnails()
            if generation ~= requestGeneration then return end
            page.error = nil
            if not response.ok or not response.status or response.status < 200 or response.status >= 300 then
                page.error = "Invidious request failed (HTTP " .. tostring(response.status or 0) .. ")"
            else
                local data = noctalia.json.decode(response.body or "")
                local source
                if type(data) == "table" then
                    if page.kind == "channel" then source = data.videos else source = data end
                end
                if type(data) ~= "table" or data.error or type(source) ~= "table"
                    or (next(source) ~= nil and source[1] == nil) then
                    page.error = type(data) == "table" and clean(data.error) or ""
                    if page.error == "" then page.error = "Invalid Invidious response" end
                else
                    page.items = normalize(source, page)
                    page.loadedAt = noctalia.nowMs()
                    if page.kind == "search" and #source > 0 then
                        page.next = {kind = "search", text = page.text, number = page.number + 1, previous = page}
                    elseif page.kind == "channel" and type(data.continuation) == "string" and data.continuation ~= "" then
                        local ancestor, repeated = page, false
                        while ancestor do
                            if ancestor.continuation == data.continuation then repeated = true end
                            ancestor = ancestor.previous
                        end
                        if not repeated then
                            page.next = {kind = "channel", id = page.id, name = page.name, number = page.number + 1,
                                continuation = data.continuation, previous = page, origin = page.origin}
                        end
                    end
                end
            end
            render()
            if not page.error then requestThumbnails() end
        end)
        if not started then page.error = "Could not start Invidious request"; render() end
    end
    function M.activate(id)
        if id == "refresh" and currentPage then
            currentPage.loadedAt = nil
            -- The host caches identical queries. Fetch here and use setQuery only to keep the panel open.
            launcher.setQuery(currentQuery)
            M.query(currentQuery)
            return
        end
        local videoId = allowed[id]
        if not videoId then return end
        if not noctalia.commandExists("mpv") then noctalia.notifyError("mpv is not installed"); return end
        local started = noctalia.runAsync({
            "mpv", "--profile=youtube", "--", "https://www.youtube.com/watch?v=" .. videoId,
        })
        if not started then noctalia.notifyError("Could not start mpv") end
    end

    function M.cancel()
        generation = generation + 1
        currentPage, allowed = nil, {}
        thumbnailQueue, queueIndex = {}, 1
    end

    return M
end)()
local mode, input = "menu", ""

function onQuery(query)
    local text = query:match("^%s*(.-)%s*$")
    input = ""
    if text == "" then
        mode = "menu"
        browser.cancel()
        launcher.setResults(query, {
            {id = "search", title = "Search", subtitle = "Find videos and channels", glyph = "search", query = "Search "},
            {id = "url", title = "Play from URL", subtitle = "Paste a YouTube link", glyph = "player-play", query = "URL "},
        })
    elseif text == "URL" or text:match("^URL%s+") then
        mode = "url"
        browser.cancel()
        input = text:match("^URL%s+(.+)$") or ""
        launcher.setResults(query, {
            {
                id = input == "" and "hint" or "play",
                title = input == "" and "Paste a YouTube URL" or "Play in mpv",
                subtitle = input ~= "" and input or nil,
                glyph = "player-play",
            },
            {id = "home", title = "← YouTube", glyph = "arrow-left", query = ""},
        })
    else
        mode = "search"
        browser.query(query)
    end
end

function onActivate(id)
    if mode == "search" then
        browser.activate(id)
    elseif mode == "url" and id == "play" and input ~= "" then
        if not noctalia.commandExists("mpv") then noctalia.notifyError("mpv is not installed"); return end
        -- Keep pasted URLs out of shell parsing, including quotes and separators.
        if not noctalia.runAsync({"mpv", "--profile=youtube", "--", input}) then
            noctalia.notifyError("Could not start mpv")
        end
    end
end
