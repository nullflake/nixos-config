--!nonstrict
local records = require("./records.luau")
local Library = require("./library.luau")
local Playback = require("./playback.luau")
local Invidious = require("./invidious.luau")
local Thumbnails = require("./thumbnails.luau")

local Module = {}
function Module.new()
    local M = {}
    local clean, validId = records.clean, records.validId
    local contains, without, record = records.contains, records.without, records.record
    local dataDir = noctalia.pluginDataDir()
    local LIST_PAGE_SIZE, PAGE_TTL_MS = 25, 60000
    local libraryStore = Library.new(dataDir)
    local playback = Playback.new(dataDir, function() if M.queueChanged then M.queueChanged() end end)
    local api = Invidious.new()
    local render
    local currentPage
    local thumbnails = Thumbnails.new(dataDir, function() return currentPage end, function() render() end)
    local generation, currentQuery = 0, ""
    local routes, allowed = {}, {}
    local channelSearchInputs = {}
    local function copyUrl(url)
        if noctalia.copyToClipboard(url, "text/plain") then
            noctalia.notify("URL copied")
        else
            noctalia.notifyError("Could not copy URL")
        end
    end
    local function copyUrlAction()
        return {id = "copy-url", title = "Copy URL", glyph = "copy"}
    end
    local function displayTitle(item)
        local saved = item.destination and contains(libraryStore.data.favorites, item.destination.id)
            or contains(libraryStore.data.later, item.id)
        return saved and ("☆ " .. item.title) or item.title
    end
    local function enrichRecord(item)
        return records.enrich(item, {libraryStore.data.history, libraryStore.data.later, playback.items})
    end
    local function play(item, url) playback.play(item and enrichRecord(item) or nil, url) end
    local function toggleQueue(item) playback.run("toggle", nil, nil, enrichRecord(item)) end
    local function historyVideos()
        local records = {}
        for _, known in ipairs(libraryStore.data.history) do
            local item = record(known)
            item.progress = playback.progress(item.id)
            table.insert(records, item)
        end
        return records
    end
    local function toggleLater(item)
        local later = without(libraryStore.data.later, item.id)
        if not contains(libraryStore.data.later, item.id) then table.insert(later, 1, enrichRecord(item)) end
        return libraryStore.save(later, libraryStore.data.history)
    end
    local function route(page)
        if not page.label then
            local label = page.kind == "video" and ("Video · " .. page.item.title .. " · " .. page.item.id)
                or page.kind == "later" and ("Watch later · Page " .. page.number)
                or page.kind == "history" and ("Watch history · Page " .. page.number)
                or page.kind == "favorites" and ("Favorite channels · Page " .. page.number)
                or page.kind == "feed" and ("Latest from favorites · Page " .. page.number)
                or page.kind == "clear" and "Confirm clear history"
                or page.kind == "clear-cache" and "Confirm clear thumbnail cache"
                or page.kind == "queue" and ("Playback queue · Page " .. page.number)
                or page.kind == "clear-queue" and "Confirm clear playback queue"
                or page.kind == "reset-queue" and "Confirm reset playback queue"
                or page.kind == "channel-search-input" and (page.name .. " · Search in channel:")
                or page.kind == "channel-search" and (page.name .. " · Search · " .. page.text .. " · Page " .. page.number)
                or page.kind == "channel" and (page.name .. " · Videos · Page " .. page.number)
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
    local function videoRoute(item, page)
        page.details = page.details or {}
        local detail = page.details[item.id] or {kind = "video", origin = page}
        detail.item, page.details[item.id] = item, detail
        return route(detail)
    end
    local function favoriteAction(page)
        return {id = "toggle-channel", title = contains(libraryStore.data.favorites, page.id)
            and "Remove from favorite channels" or "Add to favorite channels", glyph = "star"}
    end
    local function channelSearchAction(page)
        page.searchInput = page.searchInput or {kind = "channel-search-input", id = page.id,
            name = page.name, origin = page, searches = {}}
        local query = route(page.searchInput)
        channelSearchInputs[page.searchInput.label] = page.searchInput
        return {id = "search-channel", title = "Search in channel", subtitle = page.name,
            glyph = "search", query = query .. " "}
    end
    render = function()
        local page = currentPage
        if not page then return end
        local rows = {}
        allowed = {}
        if page.kind == "channel" then
            table.insert(rows, favoriteAction(page))
            table.insert(rows, copyUrlAction())
            table.insert(rows, channelSearchAction(page))
        end
        if page.groups then
            page.items = {}
            for _, group in ipairs(page.groups) do
                table.insert(page.items, {key = "channel-" .. group.channel.id, title = group.channel.title,
                    subtitle = "Channel", glyph = "user-circle", destination = group.destination})
                if group.error or not group.items or #group.items == 0 then
                    table.insert(page.items, {key = "feed-status-" .. group.channel.id,
                        title = group.channel.title .. " · " .. (group.error or (group.items and "No videos" or "Loading…")),
                        subtitle = "", glyph = group.error and "alert-circle" or "loader", status = true})
                end
                for _, item in ipairs(group.items or {}) do table.insert(page.items, item) end
            end
        end
        if page.error then
            table.insert(rows, {id = "status", title = page.error, subtitle = api.instance, glyph = "alert-circle"})
        elseif not page.items or #page.items == 0 then
            table.insert(rows, {id = "status", title = page.kind == "feed"
                and "No favorite channels" or "No results found", glyph = "search"})
        end
        for _, item in ipairs(page.items or {}) do
            local path = thumbnails.path(item.key)
            local icon = path and noctalia.fileExists(path) and path or nil
            local progress = playback.progress(item.id)
            local row = {id = item.key, title = progress and (progress .. " · " .. displayTitle(item)) or displayTitle(item),
                subtitle = item.subtitle,
                icon = icon, glyph = not icon and item.glyph or nil}
            if item.destination then row.query = route(item.destination)
            elseif not item.status then row.query = videoRoute(item, page) end
            table.insert(rows, row)
        end
        if page.next then table.insert(rows, navigation("Next page →", page.next, "arrow-right")) end
        if page.previous then table.insert(rows, navigation("Previous page", page.previous)) end
        if page.origin then
            table.insert(rows, navigation(page.origin.kind == "favorites" and "Back to favorite channels"
                or page.origin.kind == "feed" and "Back to latest videos"
                or page.origin.kind == "channel" and "Back to channel" or "Back to search", page.origin))
        end
        table.insert(rows, {id = "refresh", title = page.error and "Retry" or "Refresh", glyph = "refresh"})
        table.insert(rows, {id = "home", title = "YouTube", glyph = "arrow-left", query = ""})
        launcher.setResults(currentQuery, rows)
    end
    local laterPage, historyPage = {kind = "later", number = 1}, {kind = "history", number = 1}
    local listPages = {later = {laterPage}, history = {historyPage}, favorites = {{kind = "favorites", number = 1}},
        feed = {{kind = "feed", number = 1}}, queue = {{kind = "queue", number = 1}}}
    local clearPage = {kind = "clear", origin = historyPage}
    local clearCachePage = {kind = "clear-cache"}
    local clearQueuePage = {kind = "clear-queue", origin = listPages.queue[1]}
    local resetQueuePage = {kind = "reset-queue", origin = listPages.queue[1]}
    function M.cacheQuery() return route(clearCachePage) end
    local function listPage(kind, number)
        local pages = listPages[kind]
        pages[number] = pages[number] or {kind = kind, number = number}
        return pages[number]
    end
    function M.libraryQuery(kind)
        return route(listPages[kind][1])
    end
    local function renderLocal(page)
        local rows = {}
        allowed = {}
        if playback.error and (page.kind == "queue" or page.kind == "clear-queue") then
            table.insert(rows, {id = "status", title = playback.error, glyph = "alert-circle"})
            table.insert(rows, {id = "recover-queue", title = playback.text("reset"), glyph = "refresh",
                query = route(resetQueuePage)})
        elseif libraryStore.error and page.kind ~= "video" and page.kind ~= "clear-cache"
            and page.kind ~= "queue" and page.kind ~= "clear-queue" and page.kind ~= "reset-queue" then
            table.insert(rows, {id = "status", title = libraryStore.error, glyph = "alert-circle"})
        elseif page.kind == "video" then
            allowed.play, allowed.toggle = page.item, page.item
            allowed["copy-url"] = page.item
            allowed["queue-toggle"] = page.item
            rows = {
                {id = "play", title = contains(playback.items, page.item.id) and playback.text("play_from_here")
                    or "Play in mpv", subtitle = page.item.title, glyph = "player-play"},
                {id = "copy-url", title = "Copy URL", glyph = "copy"},
                {id = "queue-toggle", title = playback.text(contains(playback.items, page.item.id) and "remove" or "add"),
                    glyph = "list"},
                {id = "toggle", title = contains(libraryStore.data.later, page.item.id)
                    and "Remove from Watch later" or "Add to Watch later", glyph = "bookmark"},
            }
            if contains(libraryStore.data.history, page.item.id) then
                allowed["remove-history"] = page.item
                table.insert(rows, {id = "remove-history", title = "Remove from watch history", glyph = "trash"})
            end
        elseif page.kind == "reset-queue" then
            rows = {{id = "reset-queue", title = playback.text("reset_confirm"),
                subtitle = playback.text("reset_description"), glyph = "refresh"}}
        elseif page.kind == "clear-queue" then
            rows = {{id = "clear-queue", title = playback.text("clear_confirm"),
                subtitle = playback.text("clear_description"), glyph = "trash"}}
        elseif page.kind == "clear-cache" then
            rows = {{id = "clear-cache", title = "Clear thumbnail cache?",
                subtitle = "Images will download again when browsing", glyph = "trash"}}
        elseif page.kind == "clear" then
            rows = {{id = "clear", title = "Clear all watch history?", subtitle = "Watch later will be kept",
                glyph = "trash"}}
        else
            local records = page.kind == "history" and historyVideos()
                or page.kind == "favorites" and libraryStore.sortedFavorites()
                or page.kind == "queue" and playback.items or libraryStore.data[page.kind]
            if page.kind == "queue" and #records > 0 then
                table.insert(rows, {id = "queue-play", title = playback.text("play"),
                    subtitle = playback.text("play_description"), glyph = "player-play"})
                table.insert(rows, {id = "queue-clear", title = playback.text("clear"),
                    glyph = "trash", query = route(clearQueuePage)})
            end
            if page.kind == "favorites" then
                table.insert(rows, {id = "feed", title = "Latest videos from favorites", glyph = "player-play",
                    query = route(listPages.feed[1])})
            end
            local lastPage = math.max(1, math.ceil(#records / LIST_PAGE_SIZE))
            if page.number > lastPage then
                currentPage = listPage(page.kind, lastPage)
                renderLocal(currentPage); return
            end
            if #records == 0 then
                table.insert(rows, {id = "status", title = page.kind == "later"
                    and "Watch later is empty" or page.kind == "favorites"
                    and "No favorite channels" or page.kind == "queue" and playback.text("empty")
                    or "Watch history is empty", glyph = "bookmark"})
            end
            for index = (page.number - 1) * LIST_PAGE_SIZE + 1, math.min(page.number * LIST_PAGE_SIZE, #records) do
                local item = records[index]
                local channel = page.kind == "favorites"
                local key = (channel and "channel-" or "video-") .. item.id
                local path = thumbnails.path(key)
                local icon = path and noctalia.fileExists(path) and path or nil
                local query
                if channel then
                    page.channels = page.channels or {}
                    local destination = page.channels[item.id] or {kind = "channel", id = item.id,
                        name = item.title, number = 1, origin = page}
                    page.channels[item.id] = destination
                    query = route(destination)
                else query = videoRoute(item, page) end
                table.insert(rows, {id = key, title = channel and ("☆ " .. item.title)
                    or (page.kind == "queue" and (index .. ". " .. displayTitle(item)))
                    or (item.progress and (item.progress .. " · " .. displayTitle(item)) or displayTitle(item)),
                    subtitle = item.subtitle, icon = icon,
                    glyph = not icon and (channel and "user-circle" or "player-play") or nil, query = query})
            end
            if page.number < lastPage then
                table.insert(rows, navigation("Next page →", listPage(page.kind, page.number + 1), "arrow-right"))
            end
            if page.number > 1 then
                table.insert(rows, navigation("Previous page", listPage(page.kind, page.number - 1)))
            end
            if page.kind == "history" and #records > 0 then
                table.insert(rows, {id = "confirm-clear", title = "Clear watch history", glyph = "trash",
                    query = route(clearPage)})
            end
            if page.kind == "history" then
                table.insert(rows, {id = "refresh", title = "Refresh", glyph = "refresh"})
            end
        end
        if page.origin then table.insert(rows, navigation("Back", page.origin)) end
        table.insert(rows, {id = "home", title = "YouTube", glyph = "arrow-left", query = ""})
        launcher.setResults(currentQuery, rows)
    end
    function M.collectQueueEvents()
        playback.reload()
        if libraryStore.error then return end
        playback.collectEvents(function(item, token)
            return libraryStore.rememberPlayed(enrichRecord(item), token)
        end)
    end
    local function updateHistory()
        renderLocal(currentPage)
        playback.scanHistory(function()
            if currentPage and currentPage.kind == "history" then renderLocal(currentPage) end
        end)
    end
    local feedCache = {}
    local FEED_CHANNELS_PER_PAGE = 8
    local function queryFeed(page, requestGeneration)
        local favorites = libraryStore.sortedFavorites()
        local lastPage = math.max(1, math.ceil(#favorites / FEED_CHANNELS_PER_PAGE))
        if page.number > lastPage then
            page = listPage("feed", lastPage)
            currentPage = page
        end
        page.groups, page.items, page.error = {}, {}, nil
        page.origin = listPages.favorites[1]
        page.previous = page.number > 1 and listPage("feed", page.number - 1) or nil
        page.next = page.number < lastPage and listPage("feed", page.number + 1) or nil
        page.channels = page.channels or {}
        for index = (page.number - 1) * FEED_CHANNELS_PER_PAGE + 1,
            math.min(page.number * FEED_CHANNELS_PER_PAGE, #favorites) do
            local channel = favorites[index]
            local destination = page.channels[channel.id] or {kind = "channel", id = channel.id,
                name = channel.title, number = 1, origin = page}
            page.channels[channel.id] = destination
            local cached = feedCache[channel.id]
            local age = cached and (noctalia.nowMs() - cached.loadedAt)
            table.insert(page.groups, {channel = channel, destination = destination,
                items = age and age >= 0 and age < PAGE_TTL_MS and cached.items or nil})
        end
        render()
        thumbnails.request()
        -- Fetch channels one at a time, leaving HTTP capacity for image downloads.
        local index = 1
        local fetchNext
        fetchNext = function()
            if generation ~= requestGeneration then return end
            while page.groups[index] and page.groups[index].items do index = index + 1 end
            local group = page.groups[index]
            if not group then return end
            index = index + 1
            local started = api.channelVideos(group.channel.id, function(response)
                    thumbnails.pump()
                    if generation ~= requestGeneration then return end
                    local data = response.ok and response.status == 200 and noctalia.json.decode(response.body or "")
                    local source = type(data) == "table" and not data.error and data.videos
                    if type(source) ~= "table" or (next(source) ~= nil and source[1] == nil) then
                        group.error = "Could not load videos (HTTP " .. tostring(response.status or 0) .. ")"
                    else
                        group.items = {}
                        for _, item in ipairs(api.normalize(source, {kind = "channel", id = group.channel.id})) do
                            if item.id then table.insert(group.items, item) end
                            if #group.items == 3 then break end
                        end
                        feedCache[group.channel.id] = {items = group.items, loadedAt = noctalia.nowMs()}
                    end
                    render()
                    fetchNext()
                    thumbnails.request()
                end)
            if not started then
                group.error = "Could not start request · Refresh to retry"
                render()
                fetchNext()
            end
        end
        fetchNext()
    end
    function M.query(query)
        generation = generation + 1
        local requestGeneration = generation
        currentQuery, currentPage, allowed = query, nil, {}
        thumbnails.cancel()
        local text = clean(query)
        if text == "Search" then text = "" else text = text:match("^Search%s+(.+)$") or text end
        if text == "" then
            launcher.setResults(query, {
                {id = "hint", title = "Search videos and channels", glyph = "search"},
                {id = "home", title = "YouTube", glyph = "arrow-left", query = ""},
            })
            return
        end
        local page = routes[text]
        if not page then
            local matchedLabel, matchedInput
            for label, inputPage in pairs(channelSearchInputs) do
                if text:sub(1, #label + 1) == label .. " " and (not matchedLabel or #label > #matchedLabel) then
                    matchedLabel, matchedInput = label, inputPage
                end
            end
            if matchedInput then
                local term = clean(text:sub(#matchedLabel + 2))
                page = matchedInput.searches[term]
                if not page then
                    page = {kind = "channel-search", id = matchedInput.id, name = matchedInput.name,
                        text = term, number = 1, origin = matchedInput.origin}
                    matchedInput.searches[term] = page
                end
            end
        end
        page = page or {kind = "search", text = text, number = 1}
        route(page)
        currentPage = page
        if page.kind == "channel-search-input" then
            launcher.setResults(query, {
                {id = "hint", title = "Type to search in this channel", subtitle = page.name, glyph = "search"},
                navigation("Back to channel", page.origin),
                {id = "home", title = "YouTube", glyph = "arrow-left", query = ""},
            })
            return
        end
        if page.kind == "history" then updateHistory(); return end
        if page.kind == "feed" then
            if libraryStore.error then
                launcher.setResults(query, {{id = "status", title = libraryStore.error, glyph = "alert-circle"},
                    {id = "home", title = "YouTube", glyph = "arrow-left", query = ""}})
                return
            end
            queryFeed(page, requestGeneration); return
        end
        if page.kind == "video" or page.kind == "later" or page.kind == "history"
            or page.kind == "favorites" or page.kind == "clear" or page.kind == "clear-cache"
            or page.kind == "queue" or page.kind == "clear-queue" or page.kind == "reset-queue" then
            renderLocal(page); return
        end
        local age = page.loadedAt and (noctalia.nowMs() - page.loadedAt) or nil
        if page.items and not page.error and age and age >= 0 and age < PAGE_TTL_MS then
            render(); thumbnails.request(); return
        end
        page.items, page.next = nil, nil
        local rows = {{id = "status", title = "Loading…", subtitle = page.name or page.text, glyph = "loader"}}
        if page.kind == "channel" then
            table.insert(rows, 1, channelSearchAction(page))
            table.insert(rows, 1, copyUrlAction())
            table.insert(rows, 1, favoriteAction(page))
        end
        launcher.setResults(query, rows)
        local started = api.request(page, function(response)
            -- Even stale API callbacks release a shared HTTP slot needed by the image queue.
            thumbnails.pump()
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
                    page.items = api.normalize(source, page)
                    page.loadedAt = noctalia.nowMs()
                    if page.kind == "search" and #source > 0 then
                        page.next = {kind = "search", text = page.text, number = page.number + 1, previous = page}
                    elseif page.kind == "channel-search" and #source > 0 then
                        page.next = {kind = "channel-search", id = page.id, name = page.name,
                            text = page.text, number = page.number + 1, previous = page, origin = page.origin}
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
            if not page.error then thumbnails.request() end
        end)
        if not started then page.error = "Could not start Invidious request"; render() end
    end
    function M.activate(id)
        if id == "reset-queue" and currentPage and currentPage.kind == "reset-queue" and playback.error then
            if playback.reset() then playback.run("sync") end
            local query = route(listPages.queue[1])
            launcher.setQuery(query)
            M.query(query)
            return
        end
        if id == "queue-play" and currentPage and currentPage.kind == "queue" and #playback.items > 0 and not playback.error then
            playback.run("play")
            return
        end
        if id == "clear-queue" and currentPage and currentPage.kind == "clear-queue" then
            playback.run("clear")
            local query = route(listPages.queue[1])
            launcher.setQuery(query)
            M.query(query)
            return
        end
        if id == "clear-cache" and currentPage and currentPage.kind == "clear-cache" then
            thumbnails.clear()
            launcher.setQuery(currentQuery)
            renderLocal(currentPage)
            return
        end
        if id == "copy-url" and currentPage and currentPage.kind == "channel" then
            copyUrl("https://www.youtube.com/channel/" .. currentPage.id)
            return
        end
        if id == "toggle-channel" and currentPage and currentPage.kind == "channel" then
            local favorites = without(libraryStore.data.favorites, currentPage.id)
            if not contains(libraryStore.data.favorites, currentPage.id) then
                table.insert(favorites, 1, {id = currentPage.id, title = currentPage.name,
                    subtitle = "Channel · Browse videos"})
            end
            libraryStore.save(libraryStore.data.later, libraryStore.data.history, favorites)
            launcher.setQuery(currentQuery)
            if currentPage.items or currentPage.error then render()
            else
                launcher.setResults(currentQuery, {favoriteAction(currentPage), copyUrlAction(), channelSearchAction(currentPage),
                    {id = "status", title = "Loading…", subtitle = currentPage.name, glyph = "loader"}})
            end
            return
        end
        if currentPage and currentPage.kind == "video" then
            local item = allowed[id]
            if not item then return end
            if id == "play" then play(item, "https://www.youtube.com/watch?v=" .. item.id)
            elseif id == "copy-url" then copyUrl("https://www.youtube.com/watch?v=" .. item.id)
            elseif id == "queue-toggle" then
                toggleQueue(item)
                launcher.setQuery(currentQuery)
                renderLocal(currentPage)
            elseif id == "toggle" then
                toggleLater(item)
                launcher.setQuery(currentQuery)
                renderLocal(currentPage)
            elseif id == "remove-history" then
                libraryStore.save(libraryStore.data.later, without(libraryStore.data.history, item.id))
                launcher.setQuery(currentQuery)
                renderLocal(currentPage)
            end
            return
        elseif currentPage and currentPage.kind == "clear" and id == "clear" and not libraryStore.error then
            libraryStore.save(libraryStore.data.later, {})
            local query = route(historyPage)
            launcher.setQuery(query)
            M.query(query)
            return
        end
        if id == "refresh" and currentPage then
            currentPage.loadedAt = nil
            if currentPage.kind == "feed" then feedCache = {} end
            -- The host caches identical queries. Fetch here and use setQuery only to keep the panel open.
            launcher.setQuery(currentQuery)
            M.query(currentQuery)
            return
        end
    end

    function M.urlItem(url)
        local host, path = url:match("^https?://([^/]+)/(.+)$")
        local id
        if host == "youtu.be" then id = path:match("^([^?&#/]+)")
        elseif host == "youtube.com" or host == "www.youtube.com" or host == "m.youtube.com"
            or host == "music.youtube.com" then
            id = path:match("^watch%?v=([^&#]+)") or path:match("^watch%?.-&v=([^&#]+)")
                or path:match("^shorts/([^?&#/]+)") or path:match("^live/([^?&#/]+)")
                or path:match("^embed/([^?&#/]+)")
        end
        if not validId(id, false) then return nil end
        return enrichRecord({id = id, title = "YouTube · " .. id, subtitle = "Added from URL"})
    end
    M.play, M.toggleLater, M.toggleQueue = play, toggleLater, toggleQueue
    function M.isLater(item) return contains(libraryStore.data.later, item.id) end
    function M.queueTitle(item) return playback.text(contains(playback.items, item.id) and "remove" or "add") end
    function M.queueMenuTitle() return playback.text("title") end
    function M.playTitle(item, url)
        return item and contains(playback.items, item.id) and not playback.startTime(url) and playback.text("play_from_here") or "Play in mpv"
    end

    function M.cancel()
        generation = generation + 1
        currentPage, allowed = nil, {}
        thumbnails.cancel()
    end

    return M
end

return Module
