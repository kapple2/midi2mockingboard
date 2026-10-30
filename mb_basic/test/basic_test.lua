-- basic_test.lua - type BASIC lines at a DOS 3.3 prompt in MAME and log every AY-3-8910 register write.
--
-- Environment:
--   MB_LOG     absolute path of the log file to write
--   MB_LINES   the lines to type, separated by "|"; the last one must print MB_DONE when the music is over
--   MB_DONE    text that appears on the screen when the last line is finished (default FINISHED)
--   MB_SLOT    slot holding the Phasor card (default 5)
--   MB_DUMP    if set, write the player's ring (from page ring_hi, which MB_LBL gives, up to $793F with the tail copy) to this
--              file when the first note is played
--   MB_LBL     the linker's label file (MPLAY.lbl); used to find the driver's mb_paused flag
--   MB_SEND    keys to press, "<seconds after the first note>:<key>" separated by commas, key = a character or
--              ESC; the log gets "#SFX <time>" for the first key that is not ESC and "#ESC <time>" for ESC
--   MB_MENU    set: do not leave the disk's song menu; the first line answers it
--   MB_HANGUL  set for the K-HANGEUL / KBASIC disk: the screen is hi-res, so there is no text to read. The
--              test waits a fixed time between lines, and the last line must POKE 800,66 when it is done.
--              The Hangul font ($0800-$1969), KBASIC code ($8A00-$927B) and the CHRGET patch ($0350-$0372) are
--              summed at the first note and again at the end: "#HANGUL same" or "#HANGUL changed".
-- Log lines: <seconds> <chip> <register> <value> <paused>, then the "#" notes, "#SCREEN" and the 24
-- text-screen rows.

local log_path  = os.getenv("MB_LOG")
local lines     = {}
for l in (os.getenv("MB_LINES") or ""):gmatch("[^|]+") do lines[#lines + 1] = l end
local done_text = os.getenv("MB_DONE") or "FINISHED"
local slot      = tonumber(os.getenv("MB_SLOT") or "5")
local dump_path = os.getenv("MB_DUMP")
local lbl_path  = os.getenv("MB_LBL")
local hangul    = os.getenv("MB_HANGUL")
local menu      = os.getenv("MB_MENU")        -- set: the first line answers the disk's own song menu (no auto-quit)
local sends     = {}
for item in (os.getenv("MB_SEND") or ""):gmatch("[^,]+") do
  local t, k = item:match("^([%d%.]+):(.+)$")
  sends[#sends + 1] = { at = tonumber(t), key = k, done = false }
end

local m   = manager.machine
local mem = m.devices[":maincpu"].spaces["program"]
local base = 0xC000 + slot * 0x100

-- addresses of the driver's mb_paused flag and the streamer's ring_hi, from the ld65 label file ("al 007B53 .mb_paused")
local paused_addr, ring_hi_addr
if lbl_path then
  for line in io.lines(lbl_path) do
    local addr = line:match("^al (%x+) %.mb_paused$")
    if addr then paused_addr = tonumber(addr, 16) end
    addr = line:match("^al (%x+) %.ring_hi$")
    if addr then ring_hi_addr = tonumber(addr, 16) end
  end
end

local writes = {}
local notes = {}
local ora = { [0] = 0, [1] = 0 }
local latched = { [0] = 0, [1] = 0 }
local t_start = nil
local dumped = false

local function now() return m.time:as_double() end

-- the static Hangul pieces: font, KBASIC code (CODE in kbasic.map; its variables $927C-$9290 and source buffer change in normal use), the CHRGET patch
local ranges = { { "font", 0x0800, 0x1969 }, { "kbasic", 0x8A00, 0x927B }, { "chrget", 0x0350, 0x0372 } }
local function sum_ranges()
  local sums = {}
  for _, r in ipairs(ranges) do
    local s1, s2 = 0, 0
    for a = r[2], r[3] do
      local b = mem:read_u8(a)
      s1 = (s1 + b) % 65521
      s2 = (s2 + s1 * 7 + b) % 65521
    end
    sums[#sums + 1] = s1 * 65536 + s2
  end
  return sums
end
local hangul_sum

local function dump_ram()
  local f = assert(io.open(dump_path, "wb"))
  local first = ring_hi_addr and mem:read_u8(ring_hi_addr) * 256 or 0x7100
  notes[#notes + 1] = string.format("#RINGHI %02X at %04X", first / 256, ring_hi_addr or 0)
  for a = first, 0x793F do f:write(string.char(mem:read_u8(a))) end
  f:close()
end

-- Decode the 6522 traffic: ORA carries the register number or value, ORB's
-- control lines latch the address ($07) or write the data ($06).
tap = mem:install_write_tap(base, base + 0xFF, "mb", function(offset, data, mask)
  local a = offset & 0xFF
  local chip = (a >= 0x80) and 1 or 0
  local r = a & 0x0F
  if r == 1 then
    ora[chip] = data & 0xFF
  elseif r == 0 then
    local v = data & 0xFF
    if v == 0x07 then
      latched[chip] = ora[chip]
    elseif v == 0x06 then
      if not t_start and latched[chip] < 8 then
        t_start = now()
        if dump_path and not dumped then dumped = true dump_ram() end
        if hangul then hangul_sum = sum_ranges() end
      end
      local paused = paused_addr and mem:read_u8(paused_addr) or 0
      writes[#writes + 1] = string.format("%.6f %d %d %d %d", now(), chip, latched[chip], ora[chip], paused)
    end
  end
end)

local function screen_rows()
  local rows = {}
  for r = 0, 23 do
    local addr = 0x400 + (r % 8) * 0x80 + (r // 8) * 0x28
    local s = {}
    for c = 0, 39 do
      local ch = mem:read_u8(addr + c) & 0x7F
      if ch < 0x20 then ch = ch + 0x40 end
      s[#s + 1] = string.char(ch)
    end
    rows[#rows + 1] = table.concat(s)
  end
  return rows
end

local function screen_has(text)
  if hangul then return mem:read_u8(800) == 66 end
  for _, row in ipairs(screen_rows()) do
    if row:find(text, 1, true) then return true end
  end
  return false
end

-- true when the last used row of the screen is just the "]" prompt (and the cursor)
local function at_prompt()
  local last
  for _, row in ipairs(screen_rows()) do
    if row:match("%S") then last = row end
  end
  return last ~= nil and last:sub(1, 1) == "]" and not last:sub(2):match("[^%s@_`]")
end

local function finish(extra)
  if hangul and hangul_sum then
    local now_sums, changed = sum_ranges(), {}
    for i, r in ipairs(ranges) do if now_sums[i] ~= hangul_sum[i] then changed[#changed + 1] = r[1] end end
    notes[#notes + 1] = (#changed == 0) and "#HANGUL same" or ("#HANGUL changed " .. table.concat(changed, ","))
  end
  local f = assert(io.open(log_path, "w"))
  for _, line in ipairs(writes) do f:write(line, "\n") end
  for _, line in ipairs(notes) do f:write(line, "\n") end
  if extra then f:write(extra, "\n") end
  f:write("#SCREEN\n")
  if hangul then
    f:write(mem:read_u8(800) == 66 and "FINISHED\n" or "unfinished\n")
  else
    for _, row in ipairs(screen_rows()) do f:write(row, "\n") end
  end
  f:close()
  m:exit()
end

local frame, step, posted_at, done_at = 0, 0, 0, nil
local quit_sent = false
local MAX_FRAMES = 60 * tonumber(os.getenv("MB_MAX_SECONDS") or "900")

emu.register_frame_done(function()
  frame = frame + 1
  if frame > MAX_FRAMES then finish("#TIMEOUT") return end

  -- keys pressed at a time after the first note
  if t_start then
    for _, s in ipairs(sends) do
      if not s.done and now() >= t_start + s.at then
        s.done = true
        local esc = (s.key == "ESC")
        notes[#notes + 1] = string.format("%s %.6f", esc and "#ESC" or "#SFX", now())
        m.natkeyboard:post(esc and string.char(27) or s.key)
      end
    end
  end

  if step == 0 then
    if hangul then
      if frame > 3500 then step = 1 end                     -- the driver, its fonts and KBASIC are loaded
    else
      if frame > 1500 and not menu and not quit_sent and screen_has("SONG (0 = QUIT)") then
        m.natkeyboard:post("0" .. string.char(13))          -- the disk boots into its song menu: leave it
        quit_sent = true
      end
      if frame > 1500 and (menu or at_prompt()) and (menu and screen_has("SONG (0 = QUIT)") or not menu) then step = 1 end
    end
  elseif step <= #lines then
    -- a line that starts with "~" answers a running program's INPUT (no "]" prompt to wait for); "~~" waits much longer, until a song has played
    local answer = lines[step]:sub(1, 1) == "~"
    local long = lines[step]:sub(1, 2) == "~~"
    local wait = long and 2400 or answer and 600 or hangul and 600 or 60
    if step == 1 or ((frame - posted_at > wait) and (answer or hangul or at_prompt())) then
      m.natkeyboard:post((lines[step]:gsub("^~+", "")) .. string.char(13))
      posted_at = frame
      step = step + 1
    end
  else
    if screen_has(done_text) then
      done_at = done_at or frame
      if frame - done_at > 60 then finish() end
    end
  end
end)
