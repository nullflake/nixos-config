local mp = require("mp")
local utils = require("mp.utils")
local options = {queue_path = "", helper = "", python = ""}
require("mp.options").read_options(options, "queue-playback")
if options.queue_path == "" or options.helper == "" or options.python == "" then return end

local entries = {}
local loading
mp.register_event("start-file", function(event) loading = event.playlist_entry_id end)
mp.register_event("file-loaded", function()
    local file = io.open(options.queue_path, "r")
    if not file then return end
    local body = file:read("*a"); file:close()
    local queue = utils.parse_json(body)
    if type(queue) ~= "table" or type(queue.items) ~= "table" then return end
    local path = mp.get_property("path", "")
    for _, item in ipairs(queue.items) do
        if path == "https://www.youtube.com/watch?v=" .. item.id and type(item.queueToken) == "string" then
            entries[loading] = {id = item.id, token = item.queueToken}
            break
        end
    end
end)

mp.register_event("end-file", function(event)
    local entry = entries[event.playlist_entry_id]
    entries[event.playlist_entry_id] = nil
    if event.reason ~= "eof" or not entry then return end
    -- The helper serializes EOF, clear and edits; entry IDs protect a later replay.
    mp.command_native_async({name = "subprocess", playback_only = false, args = {
        options.python, options.helper, "complete", options.queue_path,
        "--queue-start=" .. entry.id, "--queue-token=" .. entry.token,
        "--queue-entry=" .. tostring(event.playlist_entry_id),
    }}, function(success, result, error)
        if not success or not result or result.status ~= 0 then
            mp.msg.error("Could not remove completed video from queue: " .. tostring(error or (result or {}).error_string))
        end
    end)
end)
