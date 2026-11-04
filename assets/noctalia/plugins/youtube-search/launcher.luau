--!nonstrict
local browser = require("./lib/browser.luau").new()
local mode, input, activeQuery, urlItem = "menu", "", "", nil

function onQuery(query)
    browser.collectQueueEvents()
    local text = query:match("^%s*(.-)%s*$")
    input, activeQuery, urlItem = "", query, nil
    if text == "" then
        mode = "menu"
        browser.cancel()
        launcher.setResults(query, {
            {id = "search", title = "Search", subtitle = "Find videos and channels", glyph = "search", query = "Search "},
            {id = "url", title = "Play from URL", subtitle = "Paste a YouTube link", glyph = "player-play", query = "URL "},
            {id = "later", title = "Watch later", subtitle = "Saved videos", glyph = "bookmark", query = browser.libraryQuery("later")},
            {id = "history", title = "Watch history", subtitle = "Recently launched videos · Latest 500",
                glyph = "history", query = browser.libraryQuery("history")},
            {id = "favorites", title = "Favorite channels", subtitle = "Saved channels",
                glyph = "star", query = browser.libraryQuery("favorites")},
            {id = "queue", title = browser.queueMenuTitle(), glyph = "list", query = browser.libraryQuery("queue")},
            {id = "cache", title = "Clear thumbnail cache", glyph = "trash", query = browser.cacheQuery()},
        })
    elseif text == "URL" or text:match("^URL%s+") then
        mode = "url"
        browser.cancel()
        input = text:match("^URL%s+(.+)$") or ""
        urlItem = browser.urlItem(input)
        local rows = {
            {
                id = input == "" and "hint" or "play",
                title = input == "" and "Paste a YouTube URL" or browser.playTitle(urlItem, input),
                subtitle = input ~= "" and input or nil,
                glyph = "player-play",
            },
        }
        if urlItem then
            table.insert(rows, {id = "queue-toggle", title = browser.queueTitle(urlItem), glyph = "list"})
            table.insert(rows, {id = "toggle", title = browser.isLater(urlItem)
                and "Remove from Watch later" or "Add to Watch later", glyph = "bookmark"})
        end
        table.insert(rows, {id = "home", title = "YouTube", glyph = "arrow-left", query = ""})
        launcher.setResults(query, rows)
    else
        mode = "search"
        browser.query(query)
    end
end

function onActivate(id)
    browser.collectQueueEvents()
    if mode == "search" then
        browser.activate(id)
    elseif mode == "url" and id == "play" and input ~= "" then
        -- Keep pasted URLs out of shell parsing, including quotes and separators.
        browser.play(urlItem, input)
    elseif mode == "url" and id == "toggle" and urlItem then
        browser.toggleLater(urlItem)
        launcher.setQuery(activeQuery)
        onQuery(activeQuery)
    elseif mode == "url" and id == "queue-toggle" and urlItem then
        browser.toggleQueue(urlItem)
        launcher.setQuery(activeQuery)
        onQuery(activeQuery)
    end
end

browser.queueChanged = function() onQuery(activeQuery) end

noctalia.state.watch("queue_revision", browser.queueChanged)
