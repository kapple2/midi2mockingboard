# Boot the player disk headless in MAME (Phasor card in slot 5), play one song, and check
# the AY register writes against the .MBF file.
#   run_test.ps1 -Disk <disk.dsk> -Song <menu number> -Mbf <file.MBF> [-Keys [-SfxAt <seconds>]]
# MAME state (cfg, nvram, a private copy of the disk) goes under <project>\mame\.
param(
    [Parameter(Mandatory)][string]$Disk,
    [Parameter(Mandatory)][int]$Song,
    [Parameter(Mandatory)][string]$Mbf,
    [switch]$Keys,
    [switch]$Loop,              # streamed song restarts when it ends; ESC at -SfxAt seconds; check with --loop
    [double]$SfxAt = 3,
    [ValidateRange(1, 7)][int]$Slot = 5,
    [switch]$NoCard,
    [switch]$ExpectBad,         # the song is not a valid MBF1 file
    [ValidateSet('load', 'stream')][string]$PlayMode = 'load'   # answer to the menu's L)OAD OR S)TREAM?
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path "$here\..\..\..").Path
$py   = "$root\.venv\Scripts\python.exe"
$mame = 'D:\opt\classic\_emul\mame0289b_x64'
$s    = "$root\mame"
'cfg','nvram','snap','sta','diff','comments','ini' | ForEach-Object { New-Item -ItemType Directory -Force "$s\$_" | Out-Null }

# Mount a throwaway copy (in the Windows temp folder, not in the project) so MAME can
# never change the disk that was built. Disk images made by the project live in src\disk.
$copy = Join-Path $env:TEMP "mb_mame_run.dsk"
Copy-Item $Disk $copy -Force
$log = "$s\mb_test.log"
Remove-Item $log -ErrorAction SilentlyContinue

$env:MB_LOG  = $log
$env:MB_SONG = "$Song"
$env:MB_MODE = if ($NoCard) { 'nocard' } elseif ($ExpectBad) { 'bad' } elseif ($Loop) { 'loop' } elseif ($Keys) { 'keys' } else { 'full' }
$env:MB_SLOT = "$Slot"
$env:MB_SFX_AT = "$SfxAt"
$env:MB_PLAYMODE = $PlayMode
$env:MB_LBL = "$root\src\mb_apple2\build\MBPLAY.lbl"
$dump = Join-Path $env:TEMP "mb_ram.bin"
Remove-Item $dump -ErrorAction SilentlyContinue
$env:MB_DUMP = $dump

$card = if ($NoCard) { @() } else { @("-sl$Slot", 'phasor') }
$mameArgs = @('apple2p') + $card + @(
    '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
    '-rompath', "$mame\roms", '-inipath', "$mame\ini;$s\ini",
    '-cfg_directory', "$s\cfg", '-nvram_directory', "$s\nvram", '-snapshot_directory', "$s\snap",
    '-state_directory', "$s\sta", '-diff_directory', "$s\diff", '-comment_directory', "$s\comments",
    '-flop1', $copy, '-autoboot_script', "$here\mb_test.lua")
$p = Start-Process -PassThru -WindowStyle Hidden -WorkingDirectory $s "$mame\mame.exe" -ArgumentList $mameArgs
if (-not $p.WaitForExit(300000)) { Stop-Process -Id $p.Id -Force; throw 'MAME timed out' }
if (-not (Test-Path $log)) { throw 'MAME exited without writing a log' }

$check = @("$here\check_log.py", $log, $Mbf)
if ($Loop) { $check = @("$here\check_loop.py", $log, $Mbf) }
elseif ($Keys) { $check += '--keys' }
if ($NoCard) { $check += '--nocard' } elseif ($ExpectBad) { $check += '--bad' } else { $check += @('--slot', "$Slot") }
if ($PlayMode -eq 'stream') { $check += '--stream' }
if (Test-Path $dump) { $check += @('--dump', $dump) }
& $py @check
exit $LASTEXITCODE
