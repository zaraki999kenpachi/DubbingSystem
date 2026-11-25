-- @description Dubbing SubOverlay
-- @version 8.0.4
-- @author zaraki999kenpachi
-- @license MIT
-- @about
--   # Dubbing SubOverlay
--   Subtitles over the REAPER Video window: transparent background, centered text, next line,
--   progress bar, 3-2-1 countdown, roles with colors, overlapping lines, karaoke highlight.
--   Reads the subtitles imported in Dubbing_Prompter.lua. Run it again to close it.
--   Requires: ReaImGui (and js_ReaScriptAPI to attach to the video window) via ReaPack.
-- Dubbing SubOverlay 0.10.0 — subtitles over the REAPER Video window (ReaImGui).
-- Reads subtitles imported in Dubbing Prompter (project ExtState DubbingSystem / subtitle_data_v1).
-- Features: transparent background, centered text, next line preview, progress bar,
-- 3-2-1 countdown before a line, roles (colors + filter), overlapping lines shown together,
-- karaoke highlight (by time, uniform speed), font / color / outline thickness, auto-fit text size,
-- presets: "subtitles on video" and "prompter" (separate big window for a second monitor).
-- Run the script again to close the running overlay (toggle). Right-click the overlay for settings.
-- Requires ReaImGui (ReaPack). Optional: js_ReaScriptAPI (to attach to the Video window).
-- Added from CH Subtitle Overlay: subtitle language Russian / English + Russian / English (second "Dubbing Subtitles"
-- track or the Prompter's original) and memory of the subtitles per video (they stay after the Prompter is closed);
-- subtitle file .ass/.ssa/.srt/.vtt next to the media; all installed fonts with Cyrillic; weight Regular..Black;
-- outline color/opacity, shadow, line spacing, text width, fade in/out; position: 9 buttons, exact X/Y %, drag with the
-- mouse, "in the black bar under the picture"; on top of a full-screen video. Menu: right mouse button.

if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("Не найден ReaImGui.\n\nУстанови: Extensions → ReaPack → Browse packages → ReaImGui.", "Dubbing SubOverlay", 0)
  return
end

local SEC, KEY = "DubbingSystem", "subtitle_data_v1"
local CFG = "DubbingSubOverlayV2"

-- re-launching the action terminates the running instance without a prompt (REAPER 6.36+)
if reaper.set_action_options then reaper.set_action_options(1) end

-- toggle: if an instance is already running, ask it to close and exit
local hb = tonumber(reaper.GetExtState(CFG, "hb") or "")
if hb and reaper.time_precise() - hb < 1.0 then
  reaper.SetExtState(CFG, "quit", "1", false)
  return
end
reaper.DeleteExtState(CFG, "quit", false)

-- ---------- settings ----------
-- mode: 1 = centered over the video, 2 = over the video at the bottom, 3 = bar below the video
local S = {
  attach = true, mode = 1, offset = 0, h = 170, size = 40, bold = true, bg = 0, title = false,
  font = 1, color = 0xFFFFFFFF, role_color = false, show_role = true, show_next = true,
  progress = true, countdown = true, autofit = true, role_filter = "",
  karaoke = false, outline = 2, multi = true,
  warn_cps = 0, show_orig = false, rec_mark = true, timer = true,
  badge = true, tc = true, tc_frames = false, actor_big = false,
  lang = "ru",   -- subtitle language: ru | both (English + Russian) | en
  text_w = 100,          -- text width, % of the panel
  gap = 0,               -- extra line spacing, px
  out_col = 0x000000FF,  -- outline color
  out_op = 100,          -- outline opacity, %
  plate = 0,             -- plate under the text (rounded black box around the text, as in CH): opacity %, 0 = none
  shadow = 0, shadow_blur = 8,   -- soft shadow: strength %, blur px (0 = off)
  fade = 0,              -- fade in / out of a line, ms (0 = off)
  dx = 0,                -- horizontal shift of the text, px
  en_dy = 2, ru_dy = 2,  -- vertical shift of the English / Russian lines, px (+ down, - up); 2 / 2 = the user's tuned grid
  edit = false,          -- "move the text with the mouse" mode (not saved)
  font_custom = "",      -- any installed font by name (applies after restarting the overlay)
  font_name = "",        -- chosen font by name
  rel = true, scale = 65,   -- text size as in CH Subtitle Overlay: % of the video height (rel) instead of pixels
  topmost = false,       -- always above other windows (it is automatic over a full-screen video)
  wt = 4,                -- weight: 1 Regular | 2 Medium | 3 Semibold | 4 Bold | 5 Black
  exact = false,         -- exact position in % of the video (pos_x / pos_y) instead of mode + offset
  pos_x = 50, pos_y = 86,
}

local DEFAULTS = {}
for k, v in pairs(S) do DEFAULTS[k] = v end

-- dub track items (cached 2 s): used for the take count and the overrun of the current line
local dub_items, dub_time = {}, -10
local function dub_list()
  local now = reaper.time_precise()
  if now - dub_time < 2 then return dub_items end
  dub_time = now; dub_items = {}
  local _, g = reaper.GetProjExtState(0, SEC, "dubbing_track_guid")
  if not g or g == "" then return dub_items end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, tg = reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
    if tg == g then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        dub_items[#dub_items + 1] = { p, p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") }
      end
      break
    end
  end
  return dub_items
end

-- takes of a line and how far the last take runs past the end of the line
local function take_stats(s)
  local n, over = 0, 0
  for _, it in ipairs(dub_list()) do
    if it[1] < s.finish and it[2] > s.start then
      n = n + 1
      if it[2] - s.finish > over then over = it[2] - s.finish end
    end
  end
  return n, over
end

-- playhead time: seconds or HH:MM:SS:FF
local function tc_text(t)
  if S.tc_frames then
    local ok, f = pcall(reaper.TimeMap_curFrameRate, 0)
    local fps = (ok and f and f > 0) and f or 25
    local n = math.floor(fps + 0.5)
    local total = math.floor(t * fps + 0.5)
    return string.format("%02d:%02d:%02d:%02d", total // (n * 3600), (total // (n * 60)) % 60, (total // n) % 60, total % n)
  end
  return string.format("%02d:%02d:%05.2f", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end

local VCOL = { ok = 0x4CAF50FF, redo = 0xFF5A5AFF, check = 0xFFD64FFF, lip = 0xFFD64FFF }
local VTXT = { ok = "ок", redo = "переписать", check = "спорно", lip = "губы не совпадают" }

local function load_settings()
  for k, d in pairs(S) do
    local v = reaper.GetExtState(CFG, k)
    if v ~= "" then
      if type(d) == "boolean" then S[k] = (v == "1")
      elseif type(d) == "number" then S[k] = tonumber(v) or d
      else S[k] = v end
    end
  end
end

local function save_settings()
  for k, v in pairs(S) do
    local s = type(v) == "boolean" and (v and "1" or "0") or tostring(v)
    reaper.SetExtState(CFG, k, s, true)
  end
end
load_settings()
if reaper.GetExtState(CFG, "warn_v2") ~= "1" then            -- one time: the red "too fast" warning is now off by default
  S.warn_cps = 0
  reaper.SetExtState(CFG, "warn_v2", "1", true)
end
-- Take the look (font, weight, size, outline, shadow, line gap) from CH Subtitle Overlay: %APPDATA%\CHSubtitleOverlay\settings.txt
local function import_ch()
  local dir = os.getenv("APPDATA")
  if not dir then return false end
  local f = io.open(dir .. "\\CHSubtitleOverlay\\settings.txt", "r")
  if not f then return false end
  local kv = {}
  for line in f:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then kv[k] = v end
  end
  f:close()
  local function num(k) local t = (kv[k] or ""):gsub(",", "."); return tonumber(t) end
  local w = num("Weight")
  if w then S.wt = w >= 800 and 5 or w >= 700 and 4 or w >= 600 and 3 or w >= 500 and 2 or 1 end
  if num("Scale") then S.rel = true; S.scale = math.max(30, math.min(400, math.floor(num("Scale") * 100 + 0.5))) end
  if num("OutlineWidth") then S.outline = math.max(0, math.min(8, num("OutlineWidth"))) end
  if num("OutlineOpacity") then S.out_op = math.floor(math.max(0, math.min(1, num("OutlineOpacity"))) * 100 + 0.5) end
  if kv.OutlineColor and kv.OutlineColor:match("^%x%x%x%x%x%x$") then S.out_col = (tonumber(kv.OutlineColor, 16) << 8) | 0xFF end
  local ta = num("Opacity") and math.floor(math.max(0, math.min(1, num("Opacity"))) * 255 + 0.5) or (S.color & 0xFF)
  if kv.Color and kv.Color:match("^%x%x%x%x%x%x$") then S.color = (tonumber(kv.Color, 16) << 8) | ta else S.color = (S.color & 0xFFFFFF00) | ta end
  if num("Background") then S.plate = math.floor(math.max(0, math.min(1, num("Background"))) * 100 + 0.5) end
  if num("ShadowStrength") then S.shadow = math.floor(math.max(0, math.min(1, num("ShadowStrength"))) * 100 + 0.5) end
  if num("ShadowBlur") then S.shadow_blur = math.floor(num("ShadowBlur") + 0.5) end
  if num("LineGap") then S.gap = math.floor(num("LineGap") + 0.5) end
  if num("Fade") then S.fade = math.max(0, math.min(1000, math.floor(num("Fade") + 0.5))) end
  if num("Width") then S.text_w = math.floor(num("Width") * 100 + 0.5) end
  if kv.Font and kv.Font ~= "" then S.font_name = kv.Font end
  S.bold = S.wt >= 4
  return true
end
if reaper.GetExtState(CFG, "ch_import_v2") ~= "1" then            -- one time: copy the CH look if CH is installed
  if import_ch() then save_settings() end
  reaper.SetExtState(CFG, "ch_import_v2", "1", true)
end
if reaper.GetExtState(CFG, "even_v2") ~= "1" then              -- one time: the tuned shifts of the even layout (EN 2 / RU 2)
  S.en_dy, S.ru_dy = 2, 2
  save_settings()
  reaper.SetExtState(CFG, "even_v2", "1", true)
end
S.edit = false
for _, k in ipairs({ "pos_x", "pos_y", "dx", "offset", "gap", "fade", "text_w", "en_dy", "ru_dy" }) do S[k] = math.floor((tonumber(S[k]) or 0) + 0.5) end
if reaper.GetExtState(CFG, "wt") == "" then                      -- older saved settings (bold on/off, 0..2)
  local ow = tonumber(reaper.GetExtState(CFG, "weight"))
  if ow then S.wt = ({ [0] = 1, [1] = 4, [2] = 5 })[math.floor(ow)] or 4 else S.wt = S.bold and 4 or 1 end
end
S.wt = math.max(1, math.min(5, math.floor(S.wt)))
S.bold = S.wt >= 4   -- Bold and Black use the bold font face

local function ulen(s) return utf8.len(s) or #s end

-- ---------- roles / palette (same order as in Dubbing Prompter) ----------
local PAL = { 0xFFD64FFF, 0x4FC2F7FF, 0x82C785FF, 0xF06192FF, 0xBA68C8FF,
              0xFF8A66FF, 0x4DB5ABFF, 0xA18880FF, 0x8FA3ADFF, 0xDCE875FF }
local ACCENT = 0x4FC2F7FF
local YELLOW = 0xFFD64FFF

-- ---------- subtitles ----------
local subs, view, roles, role_idx = {}, {}, {}, {}
local raw_cache, last_check = nil, 0
local sig_cache, tsig, sig_time = nil, nil, -10

-- saved line: start \t end \t text \t role [\t done \t mark \t note \t orig]
local function parse(raw)
  local out, rl, ri = {}, {}, {}
  for line in ((raw or "") .. "\n"):gmatch("(.-)\n") do
    local a, b, rest = line:match("^([%d%.%-]+)\t([%d%.%-]+)\t(.*)$")
    local st, en = tonumber(a), tonumber(b)
    if st and en and en > st then
      local f = {}
      for part in (rest .. "\t"):gmatch("(.-)\t") do f[#f + 1] = part end
      local text, role = f[1] or "", f[2] or ""
      text = text:gsub("\\n", "\n"):gsub("\\N", "\n"):gsub("\r", "")
      if text:match("%S") then
        out[#out + 1] = { start = st, finish = en, text = text, role = role, orig = (f[6] or ""):gsub("\\n", " "),
          done = (f[3] == "1"), verdict = ((f[8] or "") ~= "" and f[8]) or nil }
        if role ~= "" and not ri[role] then rl[#rl + 1] = role; ri[role] = #rl end -- first appearance, saved order
      end
    end
  end
  table.sort(out, function(x, y) return x.start < y.start end)
  for i, s in ipairs(out) do s.no = i end   -- same numbering as in Dubbing Prompter
  return out, rl, ri
end

-- >>> LANG BEGIN
-- ---------- languages (Russian / English / both) and memory of the subtitles ----------
-- Russian: the Prompter's translation or a track "Dubbing Subtitles..." with Russian text items.
-- English: a second "Dubbing Subtitles..." track with English text items, or the Prompter's "original".
-- The last Russian / English lists are kept in a cache file named after the video file, so they stay on the
-- video after Dubbing Prompter is closed (it removes its tracks) and come back by themselves with that video.
local SEP = package.config:sub(1, 1)
local cache_dir = reaper.GetResourcePath() .. SEP .. "DubbingSubOverlay_cache" .. SEP
local LANG_LABEL = { ru = "Русский", both = "Английский + русский", en = "Английский" }
local LANG_ORDER = { "ru", "both", "en" }
local have_en = false   -- is there any English text for the current video

local function has_cyr(t) return t:find("[\208\209]") ~= nil end   -- UTF-8 Cyrillic lead bytes

local VIDEO_EXT = { mkv = 1, mp4 = 1, avi = 1, mov = 1, webm = 1, m4v = 1, wmv = 1, mpg = 1, mpeg = 1, ts = 1, flv = 1 }
local function video_file()
  for i = 0, math.min(reaper.CountMediaItems(0), 400) - 1 do   -- the video is among the first items
    local take = reaper.GetActiveTake(reaper.GetMediaItem(0, i))
    local src = take and reaper.GetMediaItemTake_Source(take)
    local fn = src and reaper.GetMediaSourceFileName(src, "") or ""
    local ext = fn:match("%.([%w]+)$")
    if ext and VIDEO_EXT[ext:lower()] then return fn end
  end
end
local function video_key()
  local fn = video_file()
  if not fn then return nil end
  local low, h = fn:lower(), 5381
  for c = 1, #low do h = (h * 33 + low:byte(c)) % 4294967296 end
  return string.format("%08x", h)
end

-- ---- subtitle FILE next to the media: .ass / .ssa / .srt / .vtt with the same name (as in CH Subtitle Overlay) ----
local function sc_time(str)
  str = str:gsub(",", ".")
  local h, m, sec = str:match("^%s*(%d+):(%d+):([%d%.]+)")
  if not h then return 0 end
  return tonumber(h) * 3600 + tonumber(m) * 60 + (tonumber(sec) or 0)
end

local function parse_srt(txt)
  local lines, out, i = {}, {}, 1
  for l in (txt:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  while i <= #lines do
    local a, b = lines[i]:match("(%d+:%d%d:%d%d[,.]%d+)%s*%-%->%s*(%d+:%d%d:%d%d[,.]%d+)")
    if a then
      local ta, tb, tx = sc_time(a), sc_time(b), {}
      i = i + 1
      while i <= #lines and lines[i]:match("%S") do tx[#tx + 1] = (lines[i]:gsub("<[^>]+>", "")); i = i + 1 end
      if tb > ta and #tx > 0 then out[#out + 1] = { ta, tb, table.concat(tx, "\n") } end
    else
      i = i + 1
    end
  end
  return out
end

-- basic ASS/SSA: timing and text of the Dialogue lines (override tags are dropped, as in CH)
local function parse_ass(txt)
  local out = {}
  for l in (txt:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    if l:sub(1, 9):lower() == "dialogue:" then
      local rest, f = l:sub(10):gsub("^%s+", ""), {}
      for _ = 1, 9 do
        local c = rest:find(",", 1, true)
        if not c then break end
        f[#f + 1] = rest:sub(1, c - 1); rest = rest:sub(c + 1)
      end
      if #f == 9 then
        local ta, tb = sc_time(f[2]), sc_time(f[3])
        local tx = rest:gsub("\\N", "\n"):gsub("\\n", "\n"):gsub("{[^}]*}", ""):gsub("\\h", " ")
        if tb > ta and tx ~= "" then out[#out + 1] = { ta, tb, tx } end
      end
    end
  end
  return out
end

-- the media the subtitle file belongs to: the selected item, else the video
local function sidecar_path()
  local it = reaper.GetSelectedMediaItem(0, 0)
  local take = it and reaper.GetActiveTake(it)
  local src = take and reaper.GetMediaItemTake_Source(take)
  local fn = src and reaper.GetMediaSourceFileName(src, "") or ""
  if fn == "" then fn = video_file() or "" end
  if fn == "" then return nil end
  local base = fn:match("^(.*)%.[^%.\\/]+$") or fn
  for _, ext in ipairs({ ".ass", ".ssa", ".srt", ".vtt" }) do
    local f = io.open(base .. ext, "rb")
    if f then local size = f:seek("end"); f:close(); return base .. ext, size end
  end
end

local function sidecar_cues()
  local path = sidecar_path()
  if not path then return {} end
  local f = io.open(path, "rb")
  if not f then return {} end
  local txt = f:read("a") or ""
  f:close()
  txt = txt:gsub("^\239\187\191", "")   -- UTF-8 BOM
  local ext = path:match("%.(%w+)$"):lower()
  local list = (ext == "ass" or ext == "ssa") and parse_ass(txt) or parse_srt(txt)
  table.sort(list, function(x, y) return x[1] < y[1] end)
  return list
end

local function cache_write(key, lang, list)
  if not key or #list == 0 then return end
  reaper.RecursiveCreateDirectory(cache_dir, 0)
  local f = io.open(cache_dir .. key .. "." .. lang, "wb")
  if not f then return end
  for _, c in ipairs(list) do
    f:write(string.format("%.6f\t%.6f\t%s\n", c[1], c[2], (c[3]:gsub("\\", "\\\\"):gsub("\n", "\\n"))))
  end
  f:close()
end

local function cache_read(key, lang)
  local list = {}
  if not key then return list end
  local f = io.open(cache_dir .. key .. "." .. lang, "rb")
  if not f then return list end
  for line in f:lines() do
    local a, b, t = line:match("^([%d%.%-]+)\t([%d%.%-]+)\t(.*)$")
    if a and tonumber(b) > tonumber(a) then
      list[#list + 1] = { tonumber(a), tonumber(b), (t:gsub("\\(.)", function(c) return c == "n" and "\n" or c end)) }
    end
  end
  f:close()
  return list
end

-- text-item tracks "Dubbing Subtitles...": every track is classed as Russian (mostly Cyrillic) or English
local function collect_tracks()
  local ru, en = {}, {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name:find("^Dubbing Subtitles") then
      local list, cyr = {}, 0
      for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, k)
        local _, txt = reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "", false)
        txt = (txt or ""):gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if txt ~= "" then
          local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
          list[#list + 1] = { pos, pos + reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), txt }
          if has_cyr(txt) then cyr = cyr + 1 end
        end
      end
      local dst = (#list > 0 and cyr * 2 >= #list) and ru or en
      for _, c in ipairs(list) do dst[#dst + 1] = c end
    end
  end
  return ru, en
end

-- cheap signature: changes when the video, the subtitle tracks, their text/timing or the language change
local cur_vkey = nil
local function tracks_sig()
  local h, n = 5381, 0
  cur_vkey = video_key()
  local function mix(x) h = (h * 33 + x) % 4294967296 end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name:find("^Dubbing Subtitles") then
      for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, k)
        local _, txt = reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "", false)
        mix(math.floor(reaper.GetMediaItemInfo_Value(it, "D_POSITION") * 1000))
        mix(math.floor(reaper.GetMediaItemInfo_Value(it, "D_LENGTH") * 1000))
        for c = 1, #txt do mix(txt:byte(c)) end
        n = n + 1
      end
    end
  end
  local sp, ssize = sidecar_path()
  return S.lang .. "|" .. (cur_vkey or "-") .. "|" .. n .. ":" .. h .. "|" .. (sp or "-") .. (ssize or "")
end

-- Russian and English lists: tracks, else the Prompter's data, then the cache for whatever is missing
local function get_langs(base)
  local ru, en = collect_tracks()
  if #ru == 0 and #en == 0 then
    -- the Prompter keeps ONE text (the last import): decide by letters which language it is
    local pc, cyr = {}, 0
    for _, s in ipairs(base) do
      pc[#pc + 1] = { s.start, s.finish, s.text }
      if has_cyr(s.text) then cyr = cyr + 1 end
    end
    if #pc > 0 then if cyr * 2 >= #pc then ru = pc else en = pc end end
    if #en == 0 then
      for _, s in ipairs(base) do                      -- "Импорт оригинала" in the Prompter
        if (s.orig or "") ~= "" and s.orig ~= s.text then en[#en + 1] = { s.start, s.finish, s.orig } end
      end
    end
  end
  if #ru == 0 and #en == 0 then                      -- a subtitle file next to the media
    local sc = sidecar_cues()
    local cyr = 0
    for _, c in ipairs(sc) do if has_cyr(c[3]) then cyr = cyr + 1 end end
    if #sc > 0 then if cyr * 2 >= #sc then ru = sc else en = sc end end
  end
  local key = video_key()
  cache_write(key, "ru", ru); cache_write(key, "en", en)
  if #ru == 0 then ru = cache_read(key, "ru") end
  if #en == 0 then en = cache_read(key, "en") end
  return ru, en
end

local function overlap(a, b) return math.min(a[2], b[2]) - math.max(a[1], b[1]) end

-- the Prompter's row (role, done, verdict, original) of a cue with the same start time
local function base_at(base, st)
  local lo, hi, idx = 1, #base, 0
  while lo <= hi do
    local mid = (lo + hi) // 2
    if base[mid].start <= st + 0.25 then idx = mid; lo = mid + 1 else hi = mid - 1 end
  end
  for i = idx, math.max(1, idx - 3), -1 do
    local b = base[i]
    if b and math.abs(b.start - st) < 0.25 then return b end
  end
end

-- subtitles to show for the chosen language; `base` = lines parsed from the Prompter
local function compose(base)
  local ru, en = get_langs(base)
  have_en = #en > 0
  local mode = S.lang
  if LANG_LABEL[mode] == nil then mode = "ru" end
  local cyr = 0
  for _, b in ipairs(base) do if has_cyr(b.text) then cyr = cyr + 1 end end
  -- unchanged default: Russian text from the Prompter, Russian chosen -> exactly the Prompter's lines
  if mode == "ru" and #base > 0 and cyr * 2 >= #base then return base end
  local cues
  if mode == "en" then
    cues = #en > 0 and en or ru
  elseif mode == "both" and #en > 0 and #ru > 0 then
    table.sort(en, function(a, b) return a[1] < b[1] end)
    cues = {}
    for _, c in ipairs(ru) do
      local best, bo
      for _, e in ipairs(en) do
        local o = overlap(c, e)
        if o > 0 and (not bo or o > bo) then best, bo = e, o end
      end
      cues[#cues + 1] = { c[1], c[2], best and (best[3] .. "\n" .. c[3]) or c[3], c[3], best and best[3] or nil }
    end
  else
    cues = #ru > 0 and ru or en
  end
  table.sort(cues, function(a, b) return a[1] < b[1] end)
  local out = {}
  for i, c in ipairs(cues) do
    local b = base_at(base, c[1])
    out[i] = { start = c[1], finish = c[2], text = c[3], role = b and b.role or "", orig = b and b.orig or "",
      done = b and b.done or false, verdict = b and b.verdict or nil, no = i, cps_text = c[4], en_part = c[5],
      kind = (mode == "en" and #en > 0) and "en" or "ru" }
  end
  return out
end
-- <<< LANG END

local function rebuild_view()
  if S.role_filter == "" then
    view = subs
  else
    view = {}
    for _, s in ipairs(subs) do if s.role == S.role_filter then view[#view + 1] = s end end
  end
end

local function refresh()
  local t = reaper.time_precise()
  if t - last_check < 0.5 then return end
  last_check = t
  local _, raw = reaper.GetProjExtState(0, SEC, KEY)
  if t - sig_time >= 1 then sig_time = t; tsig = tracks_sig() end   -- tracks / video / language (1 s)
  if raw ~= raw_cache or tsig ~= sig_cache then
    raw_cache, sig_cache = raw, tsig
    local base
    base, roles, role_idx = parse(raw)
    subs = compose(base)
    rebuild_view()
  end
end

-- all lines active at pos (earliest start first) and the next line
local function active(pos)
  local lo, hi, idx = 1, #view, 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if view[mid].start <= pos then idx = mid; lo = mid + 1 else hi = mid - 1 end
  end
  local list = {}
  for i = idx, math.max(1, idx - 8), -1 do
    local s = view[i]
    if s and pos < s.finish then table.insert(list, 1, s) end
  end
  if not S.multi and #list > 1 then list = { list[#list] } end
  return list, view[idx + 1]
end

local function role_col(role)
  local i = role_idx[role]
  return i and PAL[((i - 1) % #PAL) + 1] or 0xFFFFFFFF
end

-- ---------- ImGui ----------
local ctx = reaper.ImGui_CreateContext("Dubbing SubOverlay")
-- ---------- fonts ----------
-- The first 9 keep their order (the saved font number of older versions). The rest: every installed font that has
-- Cyrillic (a font without Cyrillic draws Russian in another font = mixed look); a newly installed font appears by itself.
local BASE_FONTS = { "Arial", "Segoe UI", "Tahoma", "Verdana", "Roboto", "Calibri", "Georgia", "Times New Roman", "Consolas" }
-- ---- all installed fonts that really have Cyrillic ----
-- The registry lists the installed font files; every file is opened once and its character map (cmap) is checked
-- for the Cyrillic letters Ж, я, ё. The verdicts are cached in a file, so only new fonts are checked later.
local function u16(str, pos) return (str:byte(pos) << 8) | str:byte(pos + 1) end
local function u32(str, pos) return (u16(str, pos) << 16) | u16(str, pos + 2) end

-- does the sfnt font that starts at `base` in file f contain all of the code points?
local function font_has(f, base, cps)
  f:seek("set", base)
  local hdr = f:read(12)
  if not hdr or #hdr < 12 then return false end
  local nt = u16(hdr, 5)
  local dir = f:read(16 * nt)
  if not dir or #dir < 16 * nt then return false end
  local off, len
  for i = 0, nt - 1 do
    if dir:sub(i * 16 + 1, i * 16 + 4) == "cmap" then off, len = u32(dir, i * 16 + 9), u32(dir, i * 16 + 13); break end
  end
  if not off or len < 12 or len > 4000000 then return false end
  f:seek("set", off)
  local cm = f:read(len)
  if not cm or #cm < 12 then return false end
  local nsub, best = u16(cm, 3), nil
  for i = 0, nsub - 1 do
    local pid, eid, so = u16(cm, 5 + i * 8), u16(cm, 7 + i * 8), u32(cm, 9 + i * 8)
    local fmt = so + 2 <= #cm and u16(cm, so + 1) or 0
    if (fmt == 4 or fmt == 12) and (pid == 3 or pid == 0) then
      if not best or (pid == 3 and eid == 1) then best = so end
      if pid == 3 and eid == 1 then break end
    end
  end
  if not best then return false end
  local fmt = u16(cm, best + 1)
  for _, cp in ipairs(cps) do
    local ok = false
    if fmt == 4 then
      local segx2 = u16(cm, best + 7)
      local seg = segx2 // 2
      local endp, startp, deltap, rangep = best + 15, best + 17 + segx2, best + 17 + segx2 * 2, best + 17 + segx2 * 3
      for k = 0, seg - 1 do
        if u16(cm, endp + k * 2) >= cp then
          local st = u16(cm, startp + k * 2)
          if st <= cp then
            local ro = u16(cm, rangep + k * 2)
            if ro == 0 then ok = ((cp + u16(cm, deltap + k * 2)) & 0xFFFF) ~= 0
            else
              local gp = rangep + k * 2 + ro + (cp - st) * 2
              ok = gp + 1 <= #cm and u16(cm, gp) ~= 0
            end
          end
          break
        end
      end
    else   -- format 12
      local ng = u32(cm, best + 13)
      for k = 0, ng - 1 do
        local q = best + 17 + k * 12
        if q + 7 > #cm then break end
        if cp >= u32(cm, q) and cp <= u32(cm, q + 4) then ok = true; break end
      end
    end
    if not ok then return false end
  end
  return true
end

local function file_has_cyrillic(path, face)
  local f = io.open(path, "rb")
  if not f then return false end
  local ok, res = pcall(function()
    local base = 0
    local tag = f:read(4)
    if tag == "ttcf" then
      f:seek("set", 8)
      local nf = u32(f:read(4), 1)
      if (face or 0) >= nf then return false end
      f:seek("set", 12 + (face or 0) * 4)
      base = u32(f:read(4), 1)
    end
    return font_has(f, base, { 0x0416, 0x044F, 0x0451 })
  end)
  f:close()
  return ok and res or false
end

-- Font list (families that have Cyrillic). Opening the overlay must be instant, so the list comes from a cache file;
-- the registry is scanned later IN THE BACKGROUND (a little per frame) only when the cache is missing / old or when
-- "Обновить список шрифтов" is pressed.
local FLIST = reaper.GetResourcePath() .. SEP .. "DubbingSubOverlay_fontlist.txt"
local function read_fontlist()
  local f = io.open(FLIST, "rb")
  if not f then return nil, 0 end
  local names, stamp = {}, 0
  for line in f:lines() do
    line = line:gsub("\r$", "")
    local t = line:match("^#t=(%d+)")
    if t then stamp = tonumber(t) or 0 elseif line ~= "" and line:sub(1, 1) ~= "@" then names[#names + 1] = line end
  end
  f:close()
  return names, stamp
end

local FONT_KEYS = { "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
                    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" }
local FVERD = reaper.GetResourcePath() .. SEP .. "DubbingSubOverlay_fonts.txt"   -- per-face verdicts (Cyrillic yes / no)

-- stage 1: read the verdict cache; stage 2/3: one registry key per call (blocking, once each)
local function fscan_new()
  local st = { entries = {}, known = {}, fresh = {}, verdict = {}, order = {}, seen = false, key = 1, i = 1 }
  local cf = io.open(FVERD, "rb")
  if cf then
    for line in cf:lines() do
      local k, v = line:match("^(.-)\t([01])$")
      if k then st.known[k] = (v == "1") end
    end
    cf:close()
  end
  return st
end

-- the registry is read by `reg query` started in the BACKGROUND (negative timeout = do not wait) into a temp file;
-- the file is picked up in later frames, so the window never waits for it
local function fscan_launch(key, tmp)
  os.remove(tmp)
  local cmd = 'cmd.exe /c "reg query "' .. key .. '" > "' .. tmp .. '" 2>&1"'
  return pcall(reaper.ExecProcess, cmd, -1)
end

local function fscan_parse(st, text)
  local windir = os.getenv("WINDIR") or "C:\\Windows"
  for line in text:gmatch("[^\r\n]+") do
    local nm, file = line:match("^%s+(.-)%s+REG_SZ%s+(.-)%s*$")
    if nm and file then
      st.seen = true
      local path = file
      if not (file:match("^%a:") or file:match("^[\\/]")) then path = windir .. "\\Fonts\\" .. file end
      local ext = (file:match("%.(%w+)$") or ""):lower()
      if ext == "ttf" or ext == "otf" or ext == "ttc" or ext == "otc" then
        st.entries[#st.entries + 1] = { nm = nm:gsub("%s*%b()%s*$", ""), path = path, file = file }
      end
    end
  end
end

-- is the temp file complete (it exists and its size has stopped growing)? returns its text or nil
local function fscan_poll(tmp, last)
  local f = io.open(tmp, "rb")
  if not f then return nil end
  local text = f:read("a") or ""
  f:close()
  if #text > 0 and last[tmp] == #text then return text end
  last[tmp] = #text
  return nil
end

-- reads the font files for at most `budget` seconds; true when everything is done
local function fscan_step(st, budget)
  local t0 = reaper.time_precise()
  while st.i <= #st.entries do
    local e = st.entries[st.i]
    st.i = st.i + 1
    local face = 0
    for part in (e.nm .. " & "):gmatch("(.-) & ") do
      if part ~= "" then
        local ck = part .. "|" .. face
        local v = st.known[ck]
        if v == nil then v = file_has_cyrillic(e.path, face); st.fresh[#st.fresh + 1] = ck .. "\t" .. (v and "1" or "0"); st.known[ck] = v end
        if v and not st.verdict[part:lower()] then
          st.verdict[part:lower()] = part
          st.order[#st.order + 1] = part
        end
        face = face + 1
      end
    end
    if reaper.time_precise() - t0 > budget then return false end
  end
  return true
end

-- family names; the Bold / Italic variants of a family whose plain face is installed are dropped. Saves both caches.
local function fscan_finish(st)
  if not st.seen then return nil end
  if #st.fresh > 0 then
    local wf = io.open(FVERD, "ab")
    if wf then for _, l in ipairs(st.fresh) do wf:write(l, "\n") end wf:close() end
  end
  local out, seenf = {}, {}
  for _, nm in ipairs(st.order) do
    local low = nm:lower()
    local base = low:match("^(.-) bold italic$") or low:match("^(.-) bold oblique$") or low:match("^(.-) bold$")
      or low:match("^(.-) italic$") or low:match("^(.-) oblique$") or low:match("^(.-) regular$")
    local is_variant = base and st.verdict[base] ~= nil
    if not is_variant and not seenf[low] and nm:sub(1, 1) ~= "@" then seenf[low] = true; out[#out + 1] = nm end   -- "@Name" = vertical-writing duplicates
  end
  table.sort(out, function(x, y) return x:lower() < y:lower() end)
  local wf = io.open(FLIST, "wb")
  if wf then wf:write("#t=", tostring(os.time()), "\n"); for _, nm in ipairs(out) do wf:write(nm, "\n") end wf:close() end
  return out
end

local FONT_NAMES = {}
local in_base = {}
for _, f in ipairs(BASE_FONTS) do FONT_NAMES[#FONT_NAMES + 1] = f; in_base[f:lower()] = true end
local cached_fonts, cached_stamp = read_fontlist()
for _, nm in ipairs(cached_fonts or {}) do
  if not in_base[nm:lower()] then FONT_NAMES[#FONT_NAMES + 1] = nm; in_base[nm:lower()] = true end
end
-- background scan state: runs when the cache is missing or older than 30 days (Windows only)
local fs = { done = true, wait = 0, stage = 0 }
local function fonts_rescan(delay)
  if package.config:sub(1, 1) ~= "\\" or not reaper.ExecProcess then return end
  fs = { done = false, wait = delay or 0, stage = 0 }
end
if not cached_fonts or (os.time() - (cached_stamp or 0)) > 30 * 86400 then fonts_rescan(45) end
-- one small step per frame: the window is already on screen, nothing waits for it
local function font_scan_tick()
  if fs.done then return end
  if fs.wait > 0 then fs.wait = fs.wait - 1; return end
  if fs.stage == 0 then
    fs.st = fscan_new(); fs.last = {}; fs.t0 = reaper.time_precise(); fs.tmp = {}
    local base = reaper.GetResourcePath() .. SEP .. "DubbingSubOverlay_reg"
    local started = false
    for k, key in ipairs(FONT_KEYS) do
      fs.tmp[k] = base .. k .. ".tmp"
      local ok = fscan_launch(key, fs.tmp[k])
      started = started or ok
    end
    if started then fs.stage = 1 else fs.done = true end
    return
  end
  if fs.stage == 1 then                                  -- wait (frame by frame) for both registry dumps
    local texts, n = {}, 0
    for k, tmp in ipairs(fs.tmp) do
      texts[k] = fs.got and fs.got[k] or fscan_poll(tmp, fs.last)
      if texts[k] then n = n + 1 end
    end
    fs.got = texts
    if n == #fs.tmp or reaper.time_precise() - fs.t0 > 20 then
      for k, tmp in ipairs(fs.tmp) do
        if texts[k] then fscan_parse(fs.st, texts[k]) end
        os.remove(tmp)
      end
      fs.stage = 2
    end
    return
  end
  if fscan_step(fs.st, 0.006) then
    local out = fscan_finish(fs.st)
    fs.done = true; fs.st = nil
    for _, nm in ipairs(out or {}) do
      if not in_base[nm:lower()] then FONT_NAMES[#FONT_NAMES + 1] = nm; in_base[nm:lower()] = true end
    end
  end
end
if S.font_name ~= "" and S.font_custom == "" then
  local have = false
  for _, nm in ipairs(FONT_NAMES) do if nm == S.font_name then have = true end end
  if not have then S.font_custom = S.font_name end
end
local custom_idx = nil   -- index of the user's own font in FONT_NAMES
if S.font_custom ~= "" then FONT_NAMES[#FONT_NAMES + 1] = S.font_custom; custom_idx = #FONT_NAMES end   -- last item = own font
-- the saved font is remembered by name (the list differs between computers)
if S.font_name ~= "" then
  for i, nm in ipairs(FONT_NAMES) do if nm == S.font_name then S.font = i; break end end
end
if S.font < 1 or S.font > #FONT_NAMES then S.font = 1 end

local bold_flag = (reaper.ImGui_FontFlags_Bold and reaper.ImGui_FontFlags_Bold()) or 0
local fonts = {}
-- creates and attaches a font; returns false if ReaImGui refuses (then the font works after restarting the overlay)
local function ensure_font(i)
  if fonts[i] then return true end
  local name = FONT_NAMES[i]
  if not name then return false end
  pcall(function()
    local reg = reaper.ImGui_CreateFont(name, 0)
    local bold = (bold_flag ~= 0) and reaper.ImGui_CreateFont(name, bold_flag) or reg
    reaper.ImGui_Attach(ctx, reg)
    if bold ~= reg then reaper.ImGui_Attach(ctx, bold) end
    fonts[i] = { reg = reg, bold = bold }
  end)
  return fonts[i] ~= nil
end
ensure_font(1)         -- the others are made when they are picked (opening must be fast)
ensure_font(S.font)

-- "Black" weight: the family's real Black face is used (Arial -> Arial Black, Segoe UI -> Segoe UI Black): this is what CH
-- does. They are made by name, so they work even if the font scan did not list them. No such face -> the bold face is thickened.
local BLACK_OF = { ["arial"] = "Arial Black", ["segoe ui"] = "Segoe UI Black" }
local BLACK_FILE = { ["Arial Black"] = "ariblk.ttf", ["Segoe UI Black"] = "seguibl.ttf" }
local xfonts = {}
local function named_font(name)
  if xfonts[name] ~= nil then return xfonts[name] or nil end
  xfonts[name] = false
  -- the font FILE is the most reliable way to get the real Black face (a name can silently fall back to another face)
  local file = BLACK_FILE[name]
  local wd = os.getenv("WINDIR") or "C:\\Windows"
  if file then
    local path = wd .. "\\Fonts\\" .. file
    local fh = io.open(path, "rb")
    if fh then
      fh:close()
      pcall(function() local f = reaper.ImGui_CreateFont(path, 0); reaper.ImGui_Attach(ctx, f); xfonts[name] = f end)
    end
  end
  if not xfonts[name] then
    pcall(function() local f = reaper.ImGui_CreateFont(name, 0); reaper.ImGui_Attach(ctx, f); xfonts[name] = f end)
  end
  return xfonts[name] or nil
end
local thick_off = false
local diag = { want = 0, got = 0, h = 0, os = nil, cx = 0, cy = 0, hwnd = nil }   -- window position asked for / real (shown in the menu: it must not drift)
local function black_face_name(i)
  local fam = (FONT_NAMES[i] or ""):lower()
  for _, nm in ipairs(FONT_NAMES) do
    if nm:lower() == fam .. " black" then return nm end
  end
  return BLACK_OF[fam]
end
if S.wt == 5 then local bn = black_face_name(S.font); if bn then named_font(bn) end end   -- saved Black: ready before the first frame
local function cur_font()
  thick_off = false
  if S.wt == 5 then
    local nm = black_face_name(S.font)
    local f = nm and named_font(nm)
    if f then thick_off = true; return f end
  end
  local f = fonts[S.font] or fonts[1]
  return S.bold and f.bold or f.reg
end

local function push_font(f, size)
  if pcall(reaper.ImGui_PushFont, ctx, f, size) then return true end
  return pcall(reaper.ImGui_PushFont, ctx, f)
end

local function video_rect()
  if not reaper.JS_Window_Find then return nil end
  local hwnd = reaper.JS_Window_Find("Video Window", true)
  if not hwnd and reaper.JS_Window_FindEx then    -- the full-screen video window may have another title: find it by class
    local ok, h = pcall(reaper.JS_Window_FindEx, nil, nil, "REAPERVideoGLView", "")
    if ok and h then hwnd = h end
  end
  if not hwnd then return nil end
  local ok, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
  if ok and r > l and b > t then
    -- bottom edge of the picture area (client area): the window frame / invisible resize border below it is not part of the video
    local cb, ctop = b, t
    if reaper.JS_Window_GetClientRect then
      local ok2, ok3, _, ct, _, cbot = pcall(reaper.JS_Window_GetClientRect, hwnd)
      if ok2 and ok3 and cbot and ct and cbot > ct and cbot < b and cbot > b - 40 then cb = cbot end
      if ok2 and ok3 and ct and ct >= t and ct < t + 200 then ctop = ct end
    end
    return math.floor(l + 0.5), math.floor(t + 0.5), math.floor(r + 0.5), math.floor(b + 0.5), math.floor(cb + 0.5), math.floor(ctop + 0.5)
  end
end

-- ---- automatic measurement of the black bars (letterbox) of the picture ----
-- The picture is measured on the screen: the first row from the top (of the video's client area) that is not black; the
-- bottom bar is the same. To keep the text from jumping between scenes:
--   * a bar value counts only when it is seen in 3 different places of the film (3 s slots), a dark scene alone does not;
--   * once confirmed, the bar stays (full-frame scenes do not cancel it) and only a smaller confirmed value replaces it;
--   * the confirmed value is remembered for this video (as a fraction of the height), so the next run starts with it.
-- Does not run while the menu is open (the menu window would be measured as picture).
local bar_state = { key = "", est = nil, cand = nil, hist = {}, n = 0, t = -10, low = 0, status = "" }
local menu_open = false
local function detect_bar(l, t, r, b)
  local B = bar_state
  local w, h = math.floor(r - l), math.floor(b - t)
  local key = w .. "x" .. h .. "|" .. (cur_vkey or "-")
  if key ~= B.key then
    B.key = key; B.est = nil; B.cand = nil; B.hist = {}; B.n = 0; B.low = 0; B.status = "измеряю…"
    local saved = cur_vkey and tonumber(reaper.GetExtState(CFG, "bar_" .. cur_vkey))
    if saved and saved >= 0 and saved < 0.45 then B.est = math.floor(saved * h + 0.5); B.cand = B.est; B.status = "авто: полоса " .. B.est .. " px (запомнена)" end
  end
  if not (reaper.JS_GDI_GetScreenDC and reaper.JS_LICE_CreateBitmap and reaper.JS_LICE_GetDC and reaper.JS_GDI_Blit
      and reaper.JS_LICE_GetPixel and reaper.JS_LICE_DestroyBitmap) then
    B.status = "авто недоступно (нужен js_ReaScriptAPI, Windows)"; return nil
  end
  if menu_open then return B.est end
  local now = reaper.time_precise()
  local playing = (reaper.GetPlayState() & 1) == 1
  if now - B.t < 0.4 or (not playing and B.n >= 4) then return B.est end
  B.t = now
  local half = h // 2
  if w < 80 or half < 40 then return B.est end
  local scr = reaper.JS_GDI_GetScreenDC()
  if not scr then return B.est end
  local ok, found = pcall(function()
    local bmp = reaper.JS_LICE_CreateBitmap(true, w, half)
    if not bmp then return nil end
    local res
    pcall(function()
      reaper.JS_GDI_Blit(reaper.JS_LICE_GetDC(bmp), 0, 0, scr, math.floor(l), math.floor(t), w, half)
      local cols = {}
      for k = 1, 9 do cols[k] = math.floor(w * k / 10) end
      for y = 0, half - 1, 2 do
        for _, x in ipairs(cols) do
          local c = reaper.JS_LICE_GetPixel(bmp, x, y)
          if ((c >> 16) & 255) > 28 or ((c >> 8) & 255) > 28 or (c & 255) > 28 then res = y; return end
        end
      end
    end)
    reaper.JS_LICE_DestroyBitmap(bmp)
    return res
  end)
  pcall(reaper.JS_GDI_ReleaseDC, nil, scr)                      -- screen DC: window handle is NULL
  if ok and found then
    B.n = B.n + 1
    local pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    if found >= 20 and found <= h * 0.45 then
      B.low = 0
      local bk = math.floor(found / 4 + 0.5) * 4
      local e = B.hist[bk]
      if not e then e = { slots = {}, n = 0 }; B.hist[bk] = e end
      local slot = math.floor(pos / 3)
      if not e.slots[slot] then e.slots[slot] = true; e.n = e.n + 1 end
      if e.n >= 3 and (not B.cand or bk < B.cand) then
        B.cand = bk; B.est = bk
        if cur_vkey then reaper.SetExtState(CFG, "bar_" .. cur_vkey, string.format("%.4f", bk / h), true) end
      elseif not B.cand and (not B.est or B.est == 0 or found < B.est) then
        B.est = found                                         -- provisional (not confirmed yet)
      end
    elseif found < 3 then
      B.low = B.low + 1                                       -- "no bar": believed only when it repeats and no bar was confirmed
      if B.low >= 3 and not B.cand then B.est = 0 end
    end
  end
  if B.cand then B.status = string.format("авто: полоса %d px (подтверждена)", B.cand)
  elseif B.est and B.est >= 20 then B.status = string.format("авто: полоса ~%d px (проверяю)", B.est)
  elseif B.est == 0 then B.status = "авто: чёрной полосы нет"
  else B.status = "авто: измеряю…" end
  return B.est
end

-- is the video window full screen (it covers its whole monitor)? then our window must be above it
local function is_fullscreen(l, t, r, b)
  if not reaper.JS_Window_GetViewportFromRect then return false end
  local ok, sl, st, sr, sb = pcall(reaper.JS_Window_GetViewportFromRect, l, t, r, b, false)
  return ok and sl ~= nil and l <= sl + 2 and t <= st + 2 and r >= sr - 2 and b >= sb - 2
end

-- word wrap with the CURRENT font
local function wrap(text, maxw)
  local out = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    if para == "" then
      out[#out + 1] = ""
    else
      local cur = ""
      for word in para:gmatch("%S+") do
        local test = (cur == "") and word or (cur .. " " .. word)
        local w = reaper.ImGui_CalcTextSize(ctx, test)
        if w > maxw and cur ~= "" then out[#out + 1] = cur; cur = word else cur = test end
      end
      if cur ~= "" then out[#out + 1] = cur end
    end
  end
  return out
end

local fitcache, fitcount = {}, 0
local function layout(text, font, size, maxw)
  local key = text .. "|" .. S.font .. (S.bold and "b" or "r") .. S.wt .. "|" .. size .. "|" .. math.floor(maxw) .. "|" .. S.gap
  local c = fitcache[key]
  if c then return c end
  local p = push_font(font, size)
  local lines = wrap(text, maxw)
  local lh = reaper.ImGui_GetTextLineHeight(ctx) + S.gap
  local widths = {}
  for i, l in ipairs(lines) do widths[i] = (reaper.ImGui_CalcTextSize(ctx, l)) end
  if p then reaper.ImGui_PopFont(ctx) end
  c = { lines = lines, lh = lh, widths = widths }
  fitcount = fitcount + 1
  if fitcount > 300 then fitcache = {}; fitcount = 0 end
  fitcache[key] = c
  return c
end

local function fit(text, font, maxsize, maxw, maxh)
  local size = maxsize
  while true do
    local c = layout(text, font, size, maxw)
    if not S.autofit or size <= 12 or #c.lines * c.lh <= maxh then return size, c end
    size = size - 2
  end
end

local OUT = { {-1, 0}, {1, 0}, {0, -1}, {0, 1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1} }

-- draws wrapped lines centered in the window; frac (0..1) + hi enable the karaoke highlight
local dx_eff = 0   -- horizontal shift of the text this frame (slider + exact position)
-- text; Medium / Semibold / Black draw it again 4 times shifted by a fraction of a pixel (ImGui has only the
-- regular and the bold face, so the steps in between are made by thickening)
local WT_THICK = { 0, 0.3, 0.6, 0, 0.7 }
local function put(dl, x, y, col, str)
  reaper.ImGui_DrawList_AddText(dl, x, y, col, str)
  local d = (not thick_off) and WT_THICK[S.wt]
  if d and d > 0 then
    reaper.ImGui_DrawList_AddText(dl, x + d, y, col, str); reaper.ImGui_DrawList_AddText(dl, x - d, y, col, str)
    reaper.ImGui_DrawList_AddText(dl, x, y + d, col, str); reaper.ImGui_DrawList_AddText(dl, x, y - d, col, str)
  end
end

local function draw_lines(dl, wx, wy, ww, y, c, font, size, col, outline, frac, hi, plate, offs)
  local p = push_font(font, size)
  if plate then                                        -- the plate under the text (CH: rounded 6 px box, black)
    local pa = S.plate * 2.55
    if S.edit then pa = math.max(pa, 90) end           -- in the "move" mode the text always has a faint plate
    pa = math.floor(pa * math.min(1, (col & 0xFF) / math.max(1, S.color & 0xFF)) + 0.5)
    if pa > 0 then
      local mw = 0
      for i, l in ipairs(c.lines) do if l ~= "" then mw = math.max(mw, c.widths[i]) end end
      local pd = S.outline + 4
      local x0, y0 = wx + (ww - mw) / 2 + dx_eff, wy + y
      reaper.ImGui_DrawList_AddRectFilled(dl, x0 - pd, y0 - pd, x0 + mw + pd, y0 + #c.lines * c.lh + pd, pa, 6)
    end
  end
  local oc = (S.out_col & 0xFFFFFF00) | math.floor((col & 0xFF) * S.out_op / 100 + 0.5) -- outline color, alpha follows the text
  local ow = S.outline
  local nhi, off = 0, 0
  if frac then
    local total = 0
    for _, l in ipairs(c.lines) do total = total + ulen(l) end
    nhi = math.floor(total * math.max(0, math.min(1, frac)) + 0.5)
  end
  for i, l in ipairs(c.lines) do
    if l ~= "" then
      local x = wx + (ww - c.widths[i]) / 2 + dx_eff
      local yy = wy + y + (i - 1) * c.lh + (offs and offs[i] or 0)
      if S.shadow > 0 and S.shadow_blur > 0 then       -- soft shadow: two rings of dim black copies
        local sa = math.floor((col & 0xFF) * S.shadow / 100 * 0.3 + 0.5)
        if sa > 0 then
          for _, rad in ipairs({ S.shadow_blur * 0.4, S.shadow_blur * 0.8 }) do
            for _, o in ipairs(OUT) do reaper.ImGui_DrawList_AddText(dl, x + o[1] * rad, yy + o[2] * rad, sa, l) end
          end
        end
      end
      if outline and ow > 0 then
        for _, o in ipairs(OUT) do reaper.ImGui_DrawList_AddText(dl, x + o[1] * ow, yy + o[2] * ow, oc, l) end
      end
      local len = ulen(l)
      local k = frac and math.max(0, math.min(len, nhi - off)) or 0
      off = off + len
      if k <= 0 then
        put(dl, x, yy, col, l)
      elseif k >= len then
        put(dl, x, yy, hi, l)
      else
        local cut = utf8.offset(l, k + 1)
        local left, right = l:sub(1, cut - 1), l:sub(cut)
        put(dl, x, yy, hi, left)
        local lw = reaper.ImGui_CalcTextSize(ctx, left)
        put(dl, x + lw, yy, col, right)
      end
    end
  end
  if p then reaper.ImGui_PopFont(ctx) end
end

-- HEX field: the text being typed is kept between frames (it is only applied when it is 6 hex digits)
local hexbuf = {}
local function hex_field(id, label, color)
  local b = hexbuf[id]
  if not b or b.last ~= color then
    b = { text = string.format("%06X", (color >> 8) & 0xFFFFFF), last = color }
    hexbuf[id] = b
  end
  local ch, v = reaper.ImGui_InputText(ctx, label, b.text)
  if ch then
    b.text = v
    if #v == 6 and v:match("^%x+$") then return tonumber(v, 16) end
  end
end

-- a collapsible section of the menu (same groups as in the CH Subtitles settings window)
local function section(label)
  local ok, open = pcall(reaper.ImGui_CollapsingHeader, ctx, label, nil, reaper.ImGui_TreeNodeFlags_DefaultOpen())
  if not ok then return true end
  return open and true or false
end

local function draw_menu()
  local changed, c = false, false
  reaper.ImGui_TextDisabled(ctx, "сборка 25.11a · быстрый запуск, шрифты из кэша")
  if reaper.ImGui_Button(ctx, "Пресет: субтитры на видео") then
    S.attach = true; S.mode = 1; S.h = 170; S.size = 40; S.rel = true; S.scale = 65; S.bg = 0; S.title = false; changed = true
  end
  if reaper.ImGui_Button(ctx, "Пресет: суфлёр (отдельное окно)") then
    S.attach = false; S.h = 320; S.size = 64; S.rel = false; S.bg = 235; S.title = true
    S.show_next = true; S.progress = true; S.autofit = true; changed = true
  end
  reaper.ImGui_Separator(ctx)
  if reaper.ImGui_BeginCombo(ctx, "Язык субтитров", LANG_LABEL[S.lang] or LANG_LABEL.ru) then
    for _, k in ipairs(LANG_ORDER) do
      if reaper.ImGui_Selectable(ctx, LANG_LABEL[k], k == S.lang) then
        S.lang = k; changed = true; sig_cache = nil; last_check = 0; sig_time = -10
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if S.lang ~= "ru" and not have_en then
    reaper.ImGui_Text(ctx, "Английского текста нет: нужна вторая дорожка")
    reaper.ImGui_Text(ctx, "Dubbing Subtitles или импорт оригинала")
  end
  reaper.ImGui_Separator(ctx)
  c, S.attach = reaper.ImGui_Checkbox(ctx, "Привязать к видеоокну", S.attach); changed = changed or c
  if S.attach then
    if reaper.ImGui_RadioButton(ctx, "По центру видео", S.mode == 1) then S.mode = 1; S.exact = false; changed = true end
    if reaper.ImGui_RadioButton(ctx, "Поверх видео, снизу", S.mode == 2) then S.mode = 2; S.exact = false; changed = true end
    if reaper.ImGui_RadioButton(ctx, "Под видео", S.mode == 3) then S.mode = 3; S.exact = false; changed = true end
    if reaper.ImGui_RadioButton(ctx, "Как в CH: внизу картинки, в полосе", S.mode == 4) then S.mode = 4; S.exact = false; changed = true end
    reaper.ImGui_Text(ctx, string.format("окно по Y: нужно %d, на экране %s, поправка %d (высота %d)", diag.want, diag.os and tostring(diag.os) or "?", diag.cy, math.floor(diag.h + 0.5)))
    c, S.offset = reaper.ImGui_SliderInt(ctx, "Отступ, px", S.offset, -300, 300); changed = changed or c
    c, S.topmost = reaper.ImGui_Checkbox(ctx, "Всегда поверх окон (на полном экране видео автоматически)", S.topmost); changed = changed or c
    if not reaper.JS_Window_Find then reaper.ImGui_Text(ctx, "Нужен js_ReaScriptAPI (ReaPack)") end
  end
  c, S.h = reaper.ImGui_SliderInt(ctx, "Высота панели", S.h, 40, 600); changed = changed or c

  if section("Текст") then
    if reaper.ImGui_BeginCombo(ctx, "Шрифт", FONT_NAMES[S.font] or FONT_NAMES[1]) then
      for i, name in ipairs(FONT_NAMES) do
        if reaper.ImGui_Selectable(ctx, name, i == S.font) then
          S.font = i; S.font_name = name; changed = true; fitcache = {}; fitcount = 0; ensure_font(i)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if not fonts[S.font] then reaper.ImGui_Text(ctx, "Шрифт применится после перезапуска оверлея") end
    if not fs.done then reaper.ImGui_TextDisabled(ctx, "Идёт поиск шрифтов в фоне…")
    elseif reaper.ImGui_Button(ctx, "Обновить список шрифтов") then fonts_rescan(0) end
    local cf
    c, cf = reaper.ImGui_InputText(ctx, "Свой шрифт (имя, затем Enter)", S.font_custom)
    if c then S.font_custom = cf; changed = true end
    -- applied at once when the field is left / Enter is pressed (no restart needed)
    if reaper.ImGui_IsItemDeactivatedAfterEdit and reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) and S.font_custom ~= "" then
      local idx
      for i, nm in ipairs(FONT_NAMES) do if nm:lower() == S.font_custom:lower() then idx = i; break end end
      if not idx then
        if custom_idx then FONT_NAMES[custom_idx] = S.font_custom; fonts[custom_idx] = nil; idx = custom_idx
        else FONT_NAMES[#FONT_NAMES + 1] = S.font_custom; idx = #FONT_NAMES; custom_idx = idx end
      end
      S.font = idx; S.font_name = FONT_NAMES[idx]; fitcache = {}; fitcount = 0; ensure_font(idx); changed = true
    end
    c, S.rel = reaper.ImGui_Checkbox(ctx, "Размер в % от высоты видео (как в CH)", S.rel); changed = changed or c
    if S.rel then
      c, S.scale = reaper.ImGui_SliderInt(ctx, "Размер текста, %", math.floor(S.scale + 0.5), 30, 400); changed = changed or c
    else
      c, S.size = reaper.ImGui_SliderInt(ctx, "Размер текста, px", S.size, 12, 160); changed = changed or c
    end
    c, S.autofit = reaper.ImGui_Checkbox(ctx, "Автоподбор размера под панель", S.autofit); changed = changed or c
    local WLAB = { "Regular", "Medium", "Semibold", "Bold", "Black" }
    if reaper.ImGui_BeginCombo(ctx, "Насыщенность", WLAB[S.wt] or WLAB[4]) then
      for w = 1, 5 do
        if reaper.ImGui_Selectable(ctx, WLAB[w], w == S.wt) then
          S.wt = w; S.bold = w >= 4; changed = true; fitcache = {}; fitcount = 0
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if S.wt == 5 then reaper.ImGui_Text(ctx, thick_off and ("Black: " .. (black_face_name(S.font) or "")) or "Black: у этого шрифта нет Black-начертания, утолщение") end
    c, S.color = reaper.ImGui_ColorEdit4(ctx, "Цвет текста", S.color,
      reaper.ImGui_ColorEditFlags_NoInputs() | reaper.ImGui_ColorEditFlags_AlphaBar()); changed = changed or c
    local nv = hex_field("t", "HEX цвета текста", S.color)
    if nv then S.color = (nv << 8) | (S.color & 0xFF); changed = true end
    for qi, q in ipairs({ 0xFFFFFF, 0xFFE600, 0x5CE1FF, 0x7CFF6B }) do
      if qi > 1 then reaper.ImGui_SameLine(ctx) end
      if reaper.ImGui_ColorButton(ctx, "tq" .. qi, (q << 8) | 0xFF) then S.color = (q << 8) | (S.color & 0xFF); changed = true end
    end
    local top = math.floor((S.color & 0xFF) / 2.55 + 0.5)
    c, top = reaper.ImGui_SliderInt(ctx, "Прозрачность текста, %", top, 0, 100)
    if c then S.color = (S.color & 0xFFFFFF00) | math.floor(top * 2.55 + 0.5); changed = true end
    c, S.text_w = reaper.ImGui_SliderInt(ctx, "Ширина текста, % панели", S.text_w, 30, 100); changed = changed or c
    c, S.gap = reaper.ImGui_SliderInt(ctx, "Межстрочный интервал, px", S.gap, 0, 30); changed = changed or c
    if c then fitcache = {}; fitcount = 0 end
  end
  if section("Обводка и тень") then
    c, S.outline = reaper.ImGui_SliderDouble(ctx, "Толщина обводки, px", S.outline, 0, 8, "%.1f"); changed = changed or c
    local oc
    c, oc = reaper.ImGui_ColorEdit3(ctx, "Цвет обводки", S.out_col >> 8, reaper.ImGui_ColorEditFlags_NoInputs())
    if c then S.out_col = ((oc & 0xFFFFFF) << 8) | 0xFF; changed = true end
    local onv = hex_field("o", "HEX цвета обводки", S.out_col)
    if onv then S.out_col = (onv << 8) | 0xFF; changed = true end
    for qi, q in ipairs({ 0x000000, 0xFFFFFF, 0x1A1A66 }) do
      if qi > 1 then reaper.ImGui_SameLine(ctx) end
      if reaper.ImGui_ColorButton(ctx, "oq" .. qi, (q << 8) | 0xFF) then S.out_col = (q << 8) | 0xFF; changed = true end
    end
    c, S.out_op = reaper.ImGui_SliderInt(ctx, "Прозрачность обводки, %", S.out_op, 0, 100); changed = changed or c
    c, S.shadow = reaper.ImGui_SliderInt(ctx, "Тень: сила, % (0 = нет)", S.shadow, 0, 100); changed = changed or c
    c, S.shadow_blur = reaper.ImGui_SliderInt(ctx, "Тень: размытие, px", S.shadow_blur, 0, 30); changed = changed or c
  end
  if section("Подложка") then
    c, S.plate = reaper.ImGui_SliderInt(ctx, "Плашка под текстом, % (0 = нет)", S.plate, 0, 100); changed = changed or c
    c, S.bg = reaper.ImGui_SliderInt(ctx, "Фон панели: непрозрачность", S.bg, 0, 255); changed = changed or c
  end
  if section("Появление") then
    c, S.fade = reaper.ImGui_SliderInt(ctx, "Плавное появление, мс (0 = нет)", S.fade, 0, 600); changed = changed or c
  end
  if section("Положение текста") then
    c, S.dx = reaper.ImGui_SliderInt(ctx, "Сдвиг текста по горизонтали, px", S.dx, -600, 600); changed = changed or c
    c, S.en_dy = reaper.ImGui_SliderInt(ctx, "Английский: сдвиг, px (+ вниз, − вверх)", S.en_dy, -150, 150); changed = changed or c
    c, S.ru_dy = reaper.ImGui_SliderInt(ctx, "Русский: сдвиг, px (+ вниз, − вверх)", S.ru_dy, -150, 150); changed = changed or c
    local GRID = { { "↖", 12, 10 }, { "↑", 50, 10 }, { "↗", 88, 10 }, { "←", 12, 50 }, { "●", 50, 50 }, { "→", 88, 50 },
                   { "↙", 12, 90 }, { "↓", 50, 90 }, { "↘", 88, 90 } }
    for gi, g in ipairs(GRID) do
      if (gi - 1) % 3 > 0 then reaper.ImGui_SameLine(ctx) end
      if reaper.ImGui_Button(ctx, g[1] .. "##pos" .. gi, 36, 24) then S.exact = true; S.pos_x = g[2]; S.pos_y = g[3]; changed = true end
    end
    c, S.exact = reaper.ImGui_Checkbox(ctx, "Точное положение (по X / Y)", S.exact); changed = changed or c
    c, S.pos_x = reaper.ImGui_SliderInt(ctx, "Точно по горизонтали, %", math.floor(S.pos_x + 0.5), 0, 100); if c then S.exact = true; changed = true end
    c, S.pos_y = reaper.ImGui_SliderInt(ctx, "Точно по вертикали, %", math.floor(S.pos_y + 0.5), 0, 100); if c then S.exact = true; changed = true end
    c, S.edit = reaper.ImGui_Checkbox(ctx, "Двигать текст мышью (тяни по видео)", S.edit)
  end
  if section("Показ и режимы") then
    c, S.show_next = reaper.ImGui_Checkbox(ctx, "Показывать следующую реплику", S.show_next); changed = changed or c
    c, S.progress = reaper.ImGui_Checkbox(ctx, "Полоска времени реплики", S.progress); changed = changed or c
    c, S.countdown = reaper.ImGui_Checkbox(ctx, "Отсчёт 3-2-1 перед репликой", S.countdown); changed = changed or c
    c, S.karaoke = reaper.ImGui_Checkbox(ctx, "Караоке-подсветка (по времени)", S.karaoke); changed = changed or c
    c, S.multi = reaper.ImGui_Checkbox(ctx, "Показывать пересекающиеся реплики", S.multi); changed = changed or c
    c, S.show_role = reaper.ImGui_Checkbox(ctx, "Показывать имя роли", S.show_role); changed = changed or c
    c, S.role_color = reaper.ImGui_Checkbox(ctx, "Текст цветом роли", S.role_color); changed = changed or c

    local label = (S.role_filter == "") and "Все роли" or S.role_filter
    if reaper.ImGui_BeginCombo(ctx, "Роль", label) then
      if reaper.ImGui_Selectable(ctx, "Все роли", S.role_filter == "") then S.role_filter = ""; changed = true; rebuild_view() end
      for _, r in ipairs(roles) do
        if reaper.ImGui_Selectable(ctx, r, S.role_filter == r) then S.role_filter = r; changed = true; rebuild_view() end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    c, S.title = reaper.ImGui_Checkbox(ctx, "Заголовок окна", S.title); changed = changed or c
    c, S.show_orig = reaper.ImGui_Checkbox(ctx, "Оригинал мелким шрифтом под переводом", S.show_orig); changed = changed or c
    c, S.rec_mark = reaper.ImGui_Checkbox(ctx, "Красная рамка во время записи", S.rec_mark); changed = changed or c
    c, S.timer = reaper.ImGui_Checkbox(ctx, "Таймер до следующей реплики (в паузах)", S.timer); changed = changed or c
    c, S.badge = reaper.ImGui_Checkbox(ctx, "Номер, оценка и дубли текущей реплики", S.badge); changed = changed or c
    c, S.actor_big = reaper.ImGui_Checkbox(ctx, "Режим актёра: крупнее его реплики (роль в фильтре)", S.actor_big); changed = changed or c
    c, S.tc = reaper.ImGui_Checkbox(ctx, "Таймкод плейхеда", S.tc); changed = changed or c
    c, S.tc_frames = reaper.ImGui_Checkbox(ctx, "Таймкод в кадрах", S.tc_frames); changed = changed or c
    local wc = S.warn_cps
    c, wc = reaper.ImGui_SliderInt(ctx, "Предупреждать о скорости, зн/с (0 = выкл)", S.warn_cps, 0, 40); changed = changed or c
    S.warn_cps = tonumber(wc) or S.warn_cps
  end
  if changed then save_settings() end
  if reaper.ImGui_Button(ctx, "Сбросить настройки к умолчанию") then
    for k, v in pairs(DEFAULTS) do S[k] = v end
    rebuild_view(); save_settings()
  end
  reaper.ImGui_Separator(ctx)
  return reaper.ImGui_Button(ctx, "Закрыть оверлей")
end
local closing = false
local edit_moved = false

local function loop()
  font_scan_tick()
  refresh()
  reaper.SetExtState(CFG, "hb", tostring(reaper.time_precise()), false)
  if reaper.GetExtState(CFG, "quit") == "1" then closing = true end

  local playing = (reaper.GetPlayState() & 1) == 1
  local pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local act, nxt = active(pos)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12, 6)

  local wflags = reaper.ImGui_WindowFlags_NoScrollbar() | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    | reaper.ImGui_WindowFlags_NoDocking() | reaper.ImGui_WindowFlags_NoCollapse()
  if not S.title then wflags = wflags | reaper.ImGui_WindowFlags_NoTitleBar() end

  local l, t, r, b, cb, ctp
  local bar_now = nil
  local bottom_gap = nil          -- mode 4: the last text line stands this many px above the bottom edge of the video window
  if S.attach then l, t, r, b, cb, ctp = video_rect() end
  if l then
    wflags = wflags | reaper.ImGui_WindowFlags_NoMove() | reaper.ImGui_WindowFlags_NoResize()
    -- over a full-screen video (or always, if chosen) the window is "top most", otherwise the video covers it
    if reaper.ImGui_WindowFlags_TopMost and (S.topmost or is_fullscreen(l, t, r, b)) then
      wflags = wflags | reaper.ImGui_WindowFlags_TopMost()
    end
    local y, panel_h = nil, S.h
    if S.exact then y = math.max(t, math.min(b - S.h, t + (b - t) * S.pos_y / 100 - S.h / 2))   -- exact Y, % of the video
    elseif S.mode == 1 then y = (t + b) / 2 - S.h / 2 + S.offset      -- centered vertically on the video
    elseif S.mode == 4 then                                           -- like CH: the text stands on the bottom edge of the video window
      -- Same everywhere (with or without black bars, at any scene): the window height and the place of the last line
      -- never change, so the text does not jump. The size comes from the video height (as in CH).
      panel_h = math.max(S.h, (b - t) * 0.5)
      y = b - panel_h - S.offset
      bottom_gap = math.max(8, math.floor((b - t) * 0.025))
    elseif S.mode == 2 then y = b - S.h - S.offset                -- bottom edge, inside the video
    else y = b + S.offset end                                     -- below the video
    y, panel_h = math.floor(y + 0.5), math.floor(panel_h + 0.5)             -- whole pixels only: no fractions in the window geometry
    diag.want = y
    -- Keep the window where it must be on the SCREEN: its real position (the OS window) is read back and any drift is
    -- corrected (the text must not creep). Needs js_ReaScriptAPI; without it the window is simply placed.
    if diag.key ~= (l .. "," .. y) then diag.key = l .. "," .. y; diag.cx, diag.cy = 0, 0 end
    if reaper.JS_Window_Find and reaper.JS_Window_GetRect then
      if not diag.hwnd then -- the OS title is "Dubbing SubOverlay [1/1]": partial match
        diag.hwnd = reaper.JS_Window_Find("Dubbing SubOverlay", false) end
      if diag.hwnd then
        local ok2, ok3, ol, ot = pcall(reaper.JS_Window_GetRect, diag.hwnd)
        if ok2 and ok3 and ol and ot then
          diag.os = ot
          local ey, ex = y - ot, l - ol
          if math.abs(ey) >= 1 and math.abs(ey) <= 200 then diag.cy = math.max(-300, math.min(300, diag.cy + (ey > 0 and math.ceil(ey * 0.5) or math.floor(ey * 0.5)))) end
          if math.abs(ex) >= 1 and math.abs(ex) <= 200 then diag.cx = math.max(-300, math.min(300, diag.cx + (ex > 0 and math.ceil(ex * 0.5) or math.floor(ex * 0.5)))) end
        else diag.hwnd = nil end
      end
    end
    reaper.ImGui_SetNextWindowPos(ctx, l + diag.cx, y + diag.cy)
    reaper.ImGui_SetNextWindowSize(ctx, r - l, panel_h)
  else
    reaper.ImGui_SetNextWindowSize(ctx, 900, S.h, reaper.ImGui_Cond_FirstUseEver())
    reaper.ImGui_SetNextWindowPos(ctx, 200, 200, reaper.ImGui_Cond_FirstUseEver())
  end

  -- window background (black + alpha); in the bar mode the window is taller than the bar, so the backing is drawn only over the bar
  local backing = bottom_gap and S.h                  -- height of the backing strip at the bottom (bar mode only)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), backing and 0 or (S.bg & 0xFF))
  local visible, open = reaper.ImGui_Begin(ctx, "Dubbing SubOverlay", true, wflags)
  if visible then
    local ww, wh = reaper.ImGui_GetWindowSize(ctx)
    dx_eff = S.dx + (S.exact and (S.pos_x - 50) / 100 * ww or 0)
    local wx, wy = reaper.ImGui_GetWindowPos(ctx)
    diag.got = wy; diag.h = wh
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    if backing and S.bg > 0 then reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy + wh - backing, wx + ww, wy + wh, S.bg & 0xFF) end
    local font = cur_font()
    local outline = S.bg < 128

    -- what to show: active lines, or a 3-2-1 countdown before the next one
    -- actor mode: when a role is chosen, its lines are shown larger
    local boost = (S.actor_big and S.role_filter ~= "") and 1.3 or 1
    -- text size: % of the video height like in CH (grows and shrinks with the video window), else pixels
    local fsize = S.size
    if S.rel and l and b > t then fsize = math.max(10, math.floor((b - t) * 0.09 * S.scale / 100)) end
    local blocks, maxsize = {}, math.floor(fsize * boost)
    for _, s in ipairs(act) do
      blocks[#blocks + 1] = { text = s.text, role = s.role, frac = (pos - s.start) / (s.finish - s.start), s = s }
    end
    if #blocks == 0 and S.countdown and playing and nxt and nxt.start - pos > 0 and nxt.start - pos <= 3 then
      blocks[1] = { text = tostring(math.ceil(nxt.start - pos)), role = nxt.role, countdown = true }
      maxsize = math.floor(fsize * 1.5)
    end
    if S.edit and #blocks == 0 then                   -- like CH: a sample text to move / resize while there are no subtitles
      blocks[1] = { text = "Пример субтитров\nТяни мышью · колесо — размер · правая кнопка — сброс", role = "" }
    end
    local multi = #blocks > 1
    local first = blocks[1]
    local role = (not multi and first) and first.role or ""

    local pad, margin = 6, 24
    local bar_h = S.progress and 5 or 0
    local role_h = (S.show_role and role ~= "") and 22 or 0
    local maxw = (ww - margin * 2) * S.text_w / 100

    -- next line (small, dim)
    local nc, nsize, nh = nil, 0, 0
    if S.show_next and nxt and #blocks > 0 then
      nsize = math.max(12, math.floor(fsize * 0.5))
      nc = layout((nxt.text:gsub("\n", " ")), font, nsize, maxw)
      nh = #nc.lines * nc.lh
      if nh > wh * 0.3 then nc = nil; nh = 0 end
    end

    local avail = wh - pad * 2 - bar_h - role_h - nh
    if #blocks > 0 then
      local shown, displays = {}, {}
      for i, bk in ipairs(blocks) do
        local d = bk.text
        if multi and S.show_role and bk.role ~= "" then d = bk.role .. ": " .. d end
        displays[i] = d
      end
      local size = fit(table.concat(displays, "\n"), font, maxsize, maxw, math.max(avail, 10))
      local layouts, total_h = {}, 0
      for i, d in ipairs(displays) do
        layouts[i] = layout(d, font, size, maxw)
        total_h = total_h + #layouts[i].lines * layouts[i].lh
      end
      local y = pad + role_h + math.max(0, (avail - total_h) / 2)
      if bottom_gap and l and b > t then
        if S.exact then      -- exact position chosen: the block is centred at pos_y of the video window (as CH does)
          local cy = t + (S.pos_y / 100) * (b - t) - wy
          y = math.max(0, math.min(cy - total_h / 2, ((cb or b) - wy) - total_h))
        else                 -- default: the last line stands on the bottom edge of the video window (8 px gap)
          y = math.max(0, ((cb or b) - wy) - bottom_gap - total_h)
        end
      end
      -- English + Russian: fixed places from the first line to the last, whatever the number of lines. The Russian block is
      -- centred at one place (1.27 lines above the bottom edge), the English block stands on a second place above it and grows
      -- upward (its last line 2.86 lines above the bottom edge). They never overlap and never leave the video.
      local even
      if bottom_gap and l and b > t and not S.exact and S.lang == "both" and #blocks == 1 and blocks[1].s and not blocks[1].countdown then
        local c1 = layouts[1]
        local lh = c1.lh
        local n_en = blocks[1].s.en_part and #layout(blocks[1].s.en_part, font, size, maxw).lines or 0
        local n_ru = math.max(0, #c1.lines - n_en)
        local vb = (cb or b) - wy
        local ru_top = vb - 1.27 * lh - n_ru * lh / 2
        if ru_top + n_ru * lh > vb - 2 then ru_top = vb - 2 - n_ru * lh end
        local en_bot = math.min(vb - 2.86 * lh + lh / 2, ru_top)
        local en_top = en_bot - n_en * lh
        if en_top < 0 then ru_top = ru_top - en_top; en_top = 0 end
        even = {}
        for k = 1, #c1.lines do
          local want = (k <= n_en) and (en_top + (k - 1) * lh) or (ru_top + (k - n_en - 1) * lh)
          even[k] = want - (y + (k - 1) * lh)
        end
      end
      for i, bk in ipairs(blocks) do
        local c = layouts[i]
        local col
        if bk.countdown then col = ACCENT
        elseif (multi or S.role_color) and bk.role ~= "" then col = role_col(bk.role)
        else col = S.color end
        if bk.s and S.warn_cps > 0 and not bk.countdown then
          local dur = bk.s.finish - bk.s.start
          if dur > 0 and ulen((bk.s.cps_text or bk.text):gsub("\n", "")) / dur > S.warn_cps then col = 0xFF5A5AFF end   -- speed of ONE language
        end
        local frac, hi
        if S.karaoke and not bk.countdown then
          frac = bk.frac
          hi = (bk.role ~= "" and role_col(bk.role)) or YELLOW
          if hi == col then hi = (col == 0xFFFFFFFF) and YELLOW or 0xFFFFFFFF end
          col = (col & 0xFFFFFF00) | 0xB0 -- unspoken part is dimmer
        end
        if S.fade > 0 and bk.s then                      -- smooth appear / disappear
          local f = math.max(0, math.min(1, math.min(pos - bk.s.start, bk.s.finish - pos) / (S.fade / 1000)))
          col = (col & 0xFFFFFF00) | math.floor((col & 0xFF) * f + 0.5)
          if hi then hi = (hi & 0xFFFFFF00) | math.floor((hi & 0xFF) * f + 0.5) end
        end
        local offs                                       -- separate vertical shift of the English / Russian lines
        if (even or S.en_dy ~= 0 or S.ru_dy ~= 0) and bk.s and not bk.countdown then
          offs = {}
          local n_en = bk.s.en_part and #layout(bk.s.en_part, font, size, maxw).lines or 0
          for k = 1, #c.lines do
            offs[k] = ((bk.s.kind == "en" or k <= n_en) and S.en_dy or S.ru_dy) + (even and even[k] or 0)
          end
        end
        draw_lines(dl, wx, wy, ww, y, c, font, size, col, outline, frac, hi, true, offs)
        y = y + #c.lines * c.lh
      end
    end

    -- role label (single line only)
    if role_h > 0 then
      local bf = fonts[S.font] and fonts[S.font].bold or font
      draw_lines(dl, wx, wy, ww, pad, layout(role, bf, 16, maxw), bf, 16, role_col(role), outline)
    end

    -- next line
    if nc then
      local y = wh - pad - bar_h - nh
      draw_lines(dl, wx, wy, ww, y, nc, font, nsize, (S.color & 0xFFFFFF00) | 0xA0, outline)
    end

    -- status badge of the current line (bottom-left): number, verdict, takes, overrun
    local tf = cur_font()
    if S.badge and first and first.s then
      local n, over = take_stats(first.s)
      local parts = { "№" .. (first.s.no or "?") }
      if first.s.verdict then parts[#parts + 1] = VTXT[first.s.verdict] or first.s.verdict
      elseif first.s.done then parts[#parts + 1] = "записано" end
      if n > 0 then parts[#parts + 1] = "×" .. n end
      local bx, by = wx + 14, wy + wh - bar_h - 26
      local bc = (first.s.verdict and VCOL[first.s.verdict]) or 0xFFFFFFCC
      reaper.ImGui_DrawList_AddText(dl, bx, by, bc, table.concat(parts, "  "))
      if n > 0 and over > 0.25 then
        reaper.ImGui_DrawList_AddText(dl, bx + 220, by, 0xFF5A5AFF, string.format("⚠ дубль длиннее на %.1f с", over))
      end
    end

    -- playhead timecode (top-right)
    if S.tc then
      local ts = tc_text(pos)
      reaper.ImGui_DrawList_AddText(dl, wx + ww - 150, wy + 6, 0xFFFFFFA0, ts)
    end

    -- timer: seconds until the next line (shown in the quiet gaps, 3 s .. 15 s before it)
    if S.timer and #blocks == 0 and nxt and playing then
      local left = nxt.start - pos
      if left > 3 and left <= 15 then
        local tf = cur_font()
        local tsize = math.max(12, math.floor(fsize * 0.35))
        local tc = layout(string.format("следующая реплика через %d с", math.ceil(left)), tf, tsize, maxw)
        draw_lines(dl, wx, wy, ww, pad, tc, tf, tsize, (S.color & 0xFFFFFF00) | 0x90, outline)
      end
    end

    -- original line (dim) above the progress bar
    if S.show_orig and first and first.s and (first.s.orig or "") ~= "" then
      local of = cur_font()
      local oc = layout(first.s.orig, of, math.max(12, math.floor(fsize * 0.4)), maxw)
      local oh = #oc.lines * oc.lh
      draw_lines(dl, wx, wy, ww, wh - pad - bar_h - oh - 2, oc, of, math.max(12, math.floor(fsize * 0.4)),
        (S.color & 0xFFFFFF00) | 0x90, outline)
    end

    -- recording indicator: red frame while REAPER records
    if S.rec_mark and (reaper.GetPlayState() & 4) == 4 then
      local c = 0xFF3B3BFF
      reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + 3, c, 0)
      reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy + wh - 3, wx + ww, wy + wh, c, 0)
      reaper.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + 3, wy + wh, c, 0)
      reaper.ImGui_DrawList_AddRectFilled(dl, wx + ww - 3, wy, wx + ww, wy + wh, c, 0)
    end

    -- progress bar (of the first active line)
    if S.progress and first and first.s then
      local frac = math.max(0, math.min(1, first.frac))
      local x1, x2, y1, y2 = wx + 12, wx + ww - 12, wy + wh - bar_h - 3, wy + wh - 3
      reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, 0xFFFFFF30, 2)
      if frac > 0 then
        reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x1 + (x2 - x1) * frac, y2,
          (first.role ~= "" and role_col(first.role)) or 0xFFFFFFFF, 2)
      end
    end

    -- "move the text" mode: drag over the video; the position (X / Y %) is saved on release
    if S.edit then
      local ec = 0x4FC2F7FF
      reaper.ImGui_DrawList_AddRect(dl, wx + 1, wy + 1, wx + ww - 1, wy + wh - 1, ec, 0, 0, 2)
      reaper.ImGui_DrawList_AddText(dl, wx + ww / 2 - 170, wy + 4, ec, "ЛКМ тянуть · колесо = размер · ПКМ = сброс · Esc = выход")
      if reaper.ImGui_IsWindowHovered(ctx) then               -- mouse wheel = text size (as in CH)
        local mw = reaper.ImGui_GetMouseWheel(ctx)
        if mw and mw ~= 0 then
          S.rel = true
          S.scale = math.max(30, math.min(400, math.floor(S.scale * (mw > 0 and 1.08 or 1 / 1.08) + 0.5)))
          edit_moved = true
        end
      end
      if reaper.ImGui_IsWindowHovered(ctx) and reaper.ImGui_IsMouseDragging(ctx, 0, 1) then
        local mdx, mdy = reaper.ImGui_GetMouseDelta(ctx)
        if l and b > t then            -- over the video: exact position in % (the 9 buttons / sliders use the same values)
          S.exact = true
          S.pos_x = math.max(0, math.min(100, S.pos_x + mdx / ww * 100))
          S.pos_y = math.max(0, math.min(100, S.pos_y + mdy / (b - t) * 100))
        else
          S.dx = math.max(-600, math.min(600, math.floor(S.dx + mdx)))
        end
        edit_moved = true
      elseif edit_moved and not reaper.ImGui_IsMouseDown(ctx, 0) then
        edit_moved = false; save_settings()
      end
    end

    reaper.ImGui_Dummy(ctx, 1, 1)

    if S.edit and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then S.edit = false end   -- Esc = leave the move mode
    if reaper.ImGui_IsWindowHovered(ctx) and reaper.ImGui_IsMouseClicked(ctx, 1) then
      if S.edit then                                     -- like CH: right button in the move mode = reset position and size
        S.exact = true; S.pos_x = 50; S.pos_y = 86; S.scale = 100; S.rel = true; S.dx = 0; save_settings()
      else
        reaper.ImGui_OpenPopup(ctx, "dub_menu")
      end
    end
    menu_open = reaper.ImGui_BeginPopup(ctx, "dub_menu")
    if menu_open then
      local up = push_font(fonts[1].reg, 14)
      if draw_menu() then closing = true; reaper.ImGui_CloseCurrentPopup(ctx) end
      if up then reaper.ImGui_PopFont(ctx) end
      reaper.ImGui_EndPopup(ctx)
    end
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleColor(ctx, 1)
  reaper.ImGui_PopStyleVar(ctx, 2)

  if open and not closing then
    reaper.defer(loop)
  else
    reaper.DeleteExtState(CFG, "hb", false)
    reaper.DeleteExtState(CFG, "quit", false)
  end
end

reaper.atexit(function() reaper.DeleteExtState(CFG, "hb", false) end)
loop()
