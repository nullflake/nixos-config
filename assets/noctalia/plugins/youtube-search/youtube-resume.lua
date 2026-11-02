local mp = require("mp")
local options = { enabled = false, action = "", record_dir = "" }
require("mp.options").read_options(options, "youtube-resume")
if not options.enabled then return end
local utils = require("mp.utils")
local function env(name)
  local value = os.getenv(name)
  return value and value ~= "" and value or nil
end
local state = env("NOCTALIA_STATE_HOME") or env("XDG_STATE_HOME")
  or ((env("HOME") or "") .. "/.local/state")
local data = state .. "/noctalia/plugins/data/nullflake/youtube-search"
local dir = options.record_dir ~= "" and options.record_dir or (data .. "/resume")
local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a"); f:close(); return body
end
local function validId(id)
  return type(id) == "string" and #id == 11 and id:match("^[A-Za-z0-9_-]+$") ~= nil
end
local writeSerial = 0
local writerId = tostring(utils.getpid())
local function write(path, body)
  writeSerial = writeSerial + 1
  local temporary = path .. ".part." .. writerId .. "." .. writeSerial
  local f = io.open(temporary, "w")
  if not f then return false end
  local ok = f:write(body)
  local closed = f:close()
  if ok and closed and os.rename(temporary, path) then return true end
  os.remove(temporary); return false
end
local made = mp.command_native({name = "subprocess", args = {
  "@mkdir@", "-p", "-m", "700", "--", dir}, playback_only = false})
if not made or made.status ~= 0 then
  mp.msg.error("Cannot create resume storage")
  if options.action ~= "" then mp.commandv("quit", 1) end
  return
end
local function url(id) return "https://www.youtube.com/watch?v=" .. id end
local function removeResume(id, original)
  mp.commandv("delete-watch-later-config", url(id))
  if original and original ~= url(id) then mp.commandv("delete-watch-later-config", original) end
  local path = dir .. "/" .. id .. ".json"
  if utils.file_info(path) and not os.remove(path) then return false end
  return true
end
local function importOld()
  local native = mp.get_property("watch-later-dir", "")
  if native == "" then native = mp.command_native({"expand-path", "~~state/watch_later"}) end
  native = mp.command_native({"expand-path", native})
  local names = utils.readdir(native, "files") or {}
  if #names == 0 then return end
  local known = utils.parse_json(read(data .. "/library.json") or "") or {}
  if type(known) ~= "table" then return end
  local cachePath = dir .. "/.hashes.json"
  local hashes = utils.parse_json(read(cachePath) or "")
  if type(hashes) ~= "table" then hashes = {} end
  local cacheChanged = false
  local seen = {}
  for _, list in ipairs({type(known.history) == "table" and known.history or {},
    type(known.later) == "table" and known.later or {}}) do
    for _, item in ipairs(list) do
      if type(item) == "table" and validId(item.id) and not seen[item.id]
        and not utils.file_info(dir .. "/" .. item.id .. ".json") then
        seen[item.id] = true
        local hash = hashes[item.id]
        if type(hash) ~= "string" or #hash ~= 32 or not hash:match("^%x+$") then
          local result = mp.command_native({name = "subprocess", args = {"@md5sum@"},
            stdin_data = url(item.id), capture_stdout = true, playback_only = false})
          hash = result and result.status == 0 and result.stdout:match("^(%x+)")
          if hash then hashes[item.id] = hash; cacheChanged = true end
        end
        local path = hash and (native .. "/" .. hash:upper())
        local body = path and read(path)
        local position = body and tonumber(body:match("start=([%d.]+)"))
        if position and position > 0 then
          local subtitle = type(item.subtitle) == "string" and item.subtitle or ""
          local h, m, s = subtitle:match("(%d+):(%d+):(%d+)")
          local length
          if h then length = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
          else m, s = subtitle:match("(%d+):(%d+)"); length = m and (tonumber(m) * 60 + tonumber(s)) or 0 end
          if length == 0 or position < length then
            write(dir .. "/" .. item.id .. ".json", utils.format_json({id = item.id,
              title = item.title, position = position, length = length, updatedAt = (utils.file_info(path) or {}).mtime or 0}))
          end
        end
      end
    end
  end
  if cacheChanged and not write(cachePath, utils.format_json(hashes)) then
    mp.msg.error("Could not save legacy resume lookup cache")
  end
end
if options.action ~= "" then
  if options.action ~= "scan" and options.action ~= "clear" then mp.commandv("quit", 1); return end
  importOld()
  local ok = true
  if options.action == "clear" then
    ok = write(dir .. "/.reset", tostring(os.time()) .. ":" .. tostring(mp.get_time()))
    if ok then
      for _, name in ipairs(utils.readdir(dir, "files") or {}) do
        local id = name:match("^([A-Za-z0-9_-]+)%.json$")
        if validId(id) then
          local entry = utils.parse_json(read(dir .. "/" .. name) or "")
          -- Only use original URLs written by this script, never local paths.
          local original = type(entry) == "table" and type(entry.url) == "string"
            and entry.url:match("^https?://") and entry.url or nil
          if not removeResume(id, original) then ok = false end
        end
      end
    end
  end
  mp.commandv("quit", ok and 0 or 1); return
end

local id, original, position, length, title, reset
local completed, suppressed = false, false
local function saveProgress()
  if not id then return end
  if read(dir .. "/.reset") ~= reset then
    suppressed = true
    mp.set_property_bool("save-position-on-quit", false)
    removeResume(id, original)
  end
  if completed or suppressed or not position or not length or length <= 0
    or position <= 0 or position >= length then return end
  mp.commandv("write-watch-later-config")
  if not write(dir .. "/" .. id .. ".json", utils.format_json({id = id, url = original,
    title = title, position = position, length = length, updatedAt = os.time()})) then
    mp.msg.error("Could not save playback progress")
  end
end
mp.register_event("file-loaded", function()
  original = mp.get_property("path", "")
  local host, path = original:match("^https?://([^/]+)/(.+)$")
  local candidate
  if host == "youtu.be" then candidate = path:match("^([^?&#/]+)")
  elseif host == "youtube.com" or host == "www.youtube.com" or host == "m.youtube.com"
    or host == "music.youtube.com" then
    candidate = path:match("^watch%?v=([^&#]+)") or path:match("^watch%?.-&v=([^&#]+)")
      or path:match("^shorts/([^?&#/]+)") or path:match("^live/([^?&#/]+)") or path:match("^embed/([^?&#/]+)")
  end
  id = validId(candidate) and candidate or nil
  position, length, title = nil, mp.get_property_number("duration"), mp.get_property("media-title", id or "")
  completed, suppressed, reset = false, false, read(dir .. "/.reset")
end)
mp.observe_property("time-pos", "number", function(_, value) if value then position = value end end)
mp.observe_property("duration", "number", function(_, value) if value then length = value end end)
mp.observe_property("pause", "bool", function(_, paused) if paused then saveProgress() end end)
mp.add_periodic_timer(5, saveProgress)
mp.register_event("end-file", saveProgress)
mp.register_event("shutdown", saveProgress)

-- keep-open leaves the player at EOF; completed videos should start over.
mp.observe_property("eof-reached", "bool", function(_, eof)
  completed = eof == true
  mp.set_property_bool("save-position-on-quit", not eof and not suppressed)
  if eof then
    mp.commandv("delete-watch-later-config")
    if id then removeResume(id, original) end
  end
end)
