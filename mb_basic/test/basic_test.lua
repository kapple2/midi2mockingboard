-- basic_test.lua - type BASIC lines at a DOS 3.3 prompt in MAME and log every AY-3-8910 register write.
--
-- Environment:
--   MB_LOG     absolute path of the log file to write
--   MB_LINES   the lines to type, separated by "|"; the last one must print MB_DONE when the music is over
--   MB_DONE    text that appears on the screen when the last line is finished (default FINISHED)
--   MB_SLOT    slot holding the Phasor card (default 5)
--   MB_DUMP    if set, write RAM $6000-$80FF to this file when the first note is played
-- Log lines: <seconds> <chip> <register> <value> 0, then "#SCREEN" and the 24 text-screen rows.

local log_path  = os.getenv("MB_LOG")
local lines     = {}
for l in (os.getenv("MB_LINES") or ""):gmatch("[^|]+") do lines[#lines + 1] = l end
local done_text = os.getenv("MB_DONE") or "FINISHED"
local slot      = tonumber(os.getenv("MB_SLOT") or "5")
local dump_path = os.getenv("MB_DUMP")

local m   = manager.machine
local mem = m.devices[":maincpu"].spaces["program"]
local base = 0xC000 + slot * 0x100

local writes = {}
local ora = { [0] = 0, [1] = 0 }
local latched = { [0] = 0, [1] = 0 }
local dumped = false

local function now() return m.time:as_double() end

local function dump_ram()
  local f = assert(io.open(dump_path, "wb"))
  for a = 0x6000, 0x80FF do f:write(string.char(mem:read_u8(a))) end
  f:close()
end

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
      if not dumped and latched[chip] < 8 and dump_path then dumped = true dump_ram() end
      writes[#writes + 1] = string.format("%.6f %d %d %d 0", now(), chip, latched[chip], ora[chip])
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
  local f = assert(io.open(log_path, "w"))
  for _, line in ipairs(writes) do f:write(line, "\n") end
  if extra then f:write(extra, "\n") end
  f:write("#SCREEN\n")
  for _, row in ipairs(screen_rows()) do f:write(row, "\n") end
  f:close()
  m:exit()
end

local frame, step, posted_at, done_at = 0, 0, 0, nil
local quit_sent = false
local MAX_FRAMES = 60 * tonumber(os.getenv("MB_MAX_SECONDS") or "600")

emu.register_frame_done(function()
  frame = frame + 1
  if frame > MAX_FRAMES then finish("#TIMEOUT") return end
  if step == 0 then
    if frame > 1500 and not quit_sent and screen_has("SONG (0 = QUIT)") then
      m.natkeyboard:post("0" .. string.char(13))            -- the player disk boots into its song menu: leave it
      quit_sent = true
    end
    if frame > 1500 and at_prompt() then step = 1 end       -- DOS has booted (the prompt shows at about frame 1500)
  elseif step <= #lines then
    -- a line that starts with "~" answers a running program's INPUT (no "]" prompt to wait for); "~~" waits much longer, until a song has played
    local answer = lines[step]:sub(1, 1) == "~"
    local long = lines[step]:sub(1, 2) == "~~"
    if step == 1 or ((frame - posted_at > (long and 2400 or answer and 600 or 60)) and (answer or at_prompt())) then
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
