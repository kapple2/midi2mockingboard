-- mb_test.lua - drive the player disk in MAME and log every AY-3-8910 register write.
--
-- Environment:
--   MB_LOG       absolute path of the log file to write
--   MB_SONG      menu number to play (default 1)
--   MB_PLAYMODE  "load" or "stream": the answer to the menu's L)OAD OR S)TREAM? prompt
--   MB_MODE      "full" = play to the end;  "keys" = press A (sound effect) at MB_SFX_AT s, ESC 5 s later;
--                "loop" = set the player's restart switch (POKE 9,1), press ESC at MB_SFX_AT s;
--                "nocard" / "bad" = expect the player to complain instead of playing
--   MB_SFX_AT    seconds after the song starts to press A (default 3)
--   MB_SLOT      slot holding the Phasor card (default 5)
--   MB_LBL       the linker's label file; used to find the driver's mb_paused flag
--   MB_DUMP      if set, write RAM $1000-$7FFF to this file when the song starts
-- Log lines: <seconds> <chip> <register> <value> <paused>, then "#SFX <seconds>" / "#ESC <seconds>"
-- and, at the end, "#SCREEN" followed by the 24 text-screen rows.

local log_path  = os.getenv("MB_LOG")
local song      = os.getenv("MB_SONG") or "1"
local play_mode = os.getenv("MB_PLAYMODE") or "load"
local mode      = os.getenv("MB_MODE") or "full"
local slot      = tonumber(os.getenv("MB_SLOT") or "5")
local sfx_at    = tonumber(os.getenv("MB_SFX_AT") or "3")
local dump_path = os.getenv("MB_DUMP")
local lbl_path  = os.getenv("MB_LBL")

local m   = manager.machine
local mem = m.devices[":maincpu"].spaces["program"]
local base = 0xC000 + slot * 0x100

-- address of the driver's mb_paused flag, from the ld65 label file ("al 008153 .mb_paused")
local paused_addr
if lbl_path then
  for line in io.lines(lbl_path) do
    local addr = line:match("^al (%x+) %.mb_paused$")
    if addr then paused_addr = tonumber(addr, 16) end
  end
end

local writes = {}
local ora = { [0] = 0, [1] = 0 }
local latched = { [0] = 0, [1] = 0 }
local notes = {}

local function now() return m.time:as_double() end

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
      local paused = paused_addr and mem:read_u8(paused_addr) or 0
      writes[#writes + 1] = string.format("%.6f %d %d %d %d", now(), chip, latched[chip], ora[chip], paused)
    end
  end
end)

local function screen_text()
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
  for _, row in ipairs(screen_text()) do
    if row:find(text, 1, true) then return true end
  end
  return false
end

local function dump_ram()
  local f = assert(io.open(dump_path, "wb"))
  for a = 0x1000, 0x7FFF do f:write(string.char(mem:read_u8(a))) end
  f:close()
end

local motor_log = {}    -- MB_TRACE=1: accesses to the Disk II motor switches

local function finish()
  if os.getenv("MB_TRACE") == "1" then notes[#notes + 1] = "#MOTOR " .. table.concat(motor_log, " ") end
  local f = assert(io.open(log_path, "w"))
  for _, line in ipairs(writes) do f:write(line, "\n") end
  for _, line in ipairs(notes) do f:write(line, "\n") end
  f:write("#SCREEN\n")
  for _, row in ipairs(screen_text()) do f:write(row, "\n") end
  f:close()
  m:exit()
end

local frame, phase, t_start, t_sent = 0, 0, nil, nil
local pc_samples = {}       -- the program counter once a second, to see where a hang is
local trace = os.getenv("MB_TRACE") == "1"
local pause_pcs, was_paused = {}, false
if trace then
  -- every access to the slot 6 Disk II motor switches ($C0E8 off, $C0E9 on)
  tap_motor_r = mem:install_read_tap(0xC0E8, 0xC0E9, "motr", function(offset, data, mask)
    motor_log[#motor_log + 1] = string.format("%.2f:R%04X", m.time:as_double(), offset)
  end)
  tap_motor_w = mem:install_write_tap(0xC0E8, 0xC0E9, "motw", function(offset, data, mask)
    motor_log[#motor_log + 1] = string.format("%.2f:W%04X", m.time:as_double(), offset)
  end)
end
local MAX_FRAMES = 60 * tonumber(os.getenv("MB_MAX_SECONDS") or "900")

emu.register_frame_done(function()
  frame = frame + 1
  if frame % 60 == 0 and #pc_samples < 40 then
    pc_samples[#pc_samples + 1] = string.format("%04X", m.devices[":maincpu"].state["PC"].value)
  end
  -- MB_TRACE=1: where the CPU is, every frame, during the first pause (a disk refill)
  if trace and paused_addr and #pause_pcs < 200 then
    if mem:read_u8(paused_addr) == 1 then
      pause_pcs[#pause_pcs + 1] = string.format("%04X", m.devices[":maincpu"].state["PC"].value)
      was_paused = true
    elseif was_paused then
      notes[#notes + 1] = "#PAUSEPC " .. table.concat(pause_pcs, " ")
      was_paused = false
      pause_pcs = { "done" }
    end
  end
  if frame > MAX_FRAMES then
    -- a hang: say where the CPU is and what the disk IOB holds, to help find out why
    local cpu = m.devices[":maincpu"]
    notes[#notes + 1] = "#TIMEOUT"
    notes[#notes + 1] = string.format("#PC %04X SP %02X A %02X X %02X Y %02X", cpu.state["PC"].value,
      cpu.state["SP"].value, cpu.state["A"].value, cpu.state["X"].value, cpu.state["Y"].value)
    local pc = cpu.state["PC"].value
    local code = {}
    for i = -12, 19 do code[#code + 1] = string.format("%02X", mem:read_u8(pc + i)) end
    notes[#notes + 1] = string.format("#CODE %04X: ", pc - 12) .. table.concat(code, " ")
    notes[#notes + 1] = "#PCS " .. table.concat(pc_samples, " ")
    if lbl_path then
      for line in io.lines(lbl_path) do
        local addr = line:match("^al (%x+) %.iob$")
        if addr then
          local b = {}
          for i = 0, 17 do b[#b + 1] = string.format("%02X", mem:read_u8(tonumber(addr, 16) + i)) end
          notes[#notes + 1] = "#IOB " .. table.concat(b, " ")
        end
      end
    end
    finish() return
  end

  -- the player's "start again" switch (POKE 9,1); the menu clears it before each CALL, so keep setting it
  if mode == "loop" and phase >= 1 and phase <= 4 then mem:write_u8(9, 1) end
  if phase == 0 then
    if screen_has("SONG (0 = QUIT)") then
      m.natkeyboard:post(song .. string.char(13))
      phase = 6
    end
  elseif phase == 6 then
    -- songs of up to 7 tracks ask "L)OAD OR S)TREAM?"; longer ones go straight to streaming
    if screen_has("L)OAD OR S)TREAM") then
      notes[#notes + 1] = string.format("#CHOSE %.6f", now())
      m.natkeyboard:post((play_mode == "stream") and "S" or "L")
      phase = (mode == "nocard" or mode == "bad") and 4 or 1
    elseif screen_has("STREAMING") or screen_has("LOADING") then
      notes[#notes + 1] = string.format("#CHOSE %.6f", now())
      phase = (mode == "nocard" or mode == "bad") and 4 or 1
    end
  elseif phase == 1 then
    -- the first write to registers 0-7 is the start of the song (startup only silences 8-10)
    for _, w in ipairs(writes) do
      local t, chip, reg = w:match("^(%S+) (%d) (%d+)")
      if tonumber(reg) < 8 then t_start = tonumber(t) break end
    end
    if t_start then
      if dump_path then dump_ram() end
      phase = 2
    end
  elseif phase == 2 then
    if mode == "loop" then
      -- the song restarts by itself; stop it with ESC part-way through the second time
      if now() >= t_start + sfx_at then
        notes[#notes + 1] = string.format("#ESC %.6f", now())
        m.natkeyboard:post(string.char(27))
        phase = 4
      end
    elseif mode == "keys" then
      if now() >= t_start + sfx_at then
        notes[#notes + 1] = string.format("#SFX %.6f", now())
        m.natkeyboard:post("A")
        phase = 3
      end
    else
      phase = 4
    end
  elseif phase == 3 then
    if now() >= t_start + sfx_at + 5 then
      notes[#notes + 1] = string.format("#ESC %.6f", now())
      m.natkeyboard:post(string.char(27))
      phase = 4
    end
  elseif phase == 4 then
    -- "nocard" / "bad": the player has nothing to play and prints its complaint instead of DONE
    if screen_has("DONE") or screen_has("NO MOCKINGBOARD FOUND") or screen_has("NOT AN MBF1 FILE")
       or screen_has("DISK ERROR") then
      t_sent = t_sent or frame
      if frame - t_sent > 30 then finish() end
    end
  end
end)
