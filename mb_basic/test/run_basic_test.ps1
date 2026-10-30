# Boot a DOS 3.3 disk in MAME (headless, Phasor card), type BASIC lines, and check the music
# that the Apple II plays against the expected .MBF file.
#   run_basic_test.ps1 -Disk <disk.dsk> -Play '& MPLAY "!CDE"' -Expect <file.MBF>
#   run_basic_test.ps1 -Disk <disk.dsk> -Lines '10 & MPLAY "NAME"|20 PRINT "FIN";"ISHED"|RUN' -Expect <file.MBF>
# MAME state goes under <project>\mame\; the disk is mounted as a copy in the Windows temp folder.
# -Play is one statement typed in immediate mode (the test adds the line that prints FINISHED);
# -Lines is a complete list of lines, separated by |, that must end by printing FINISHED. A DOS
# command such as the BLOAD behind & MPLAY "NAME" needs a program: in immediate mode DOS reuses
# the input buffer that holds the rest of the line.
param(
    [Parameter(Mandatory)][string]$Disk,
    [string]$Play,
    [string]$Lines,
    [Parameter(Mandatory)][string]$Expect,      # the .MBF file the Apple II should play
    [ValidateRange(1, 7)][int]$Slot = 5
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path "$here\..\..\..").Path
$py   = "$root\.venv\Scripts\python.exe"
$mame = 'D:\opt\classic\_emul\mame0289b_x64'
$s    = "$root\mame"
'cfg','nvram','snap','sta','diff','comments','ini' | ForEach-Object { New-Item -ItemType Directory -Force "$s\$_" | Out-Null }

$copy = Join-Path $env:TEMP 'mb_basic_run.dsk'
Copy-Item $Disk $copy -Force
$log = "$s\mb_basic.log"
Remove-Item $log -ErrorAction SilentlyContinue
$dump = Join-Path $env:TEMP 'mb_basic_ram.bin'
Remove-Item $dump -ErrorAction SilentlyContinue

# The line prints FIN";"ISHED so that the typed text does not already contain the word the test waits for.
$env:MB_LOG   = $log
if (-not $Lines) { $Lines = $Play + ': PRINT "FIN";"ISHED"' }
$env:MB_LINES = 'HIMEM: 24576|BLOAD MPLAY|CALL 35840|' + $Lines
$env:MB_DONE  = 'FINISHED'
$env:MB_SLOT  = "$Slot"
$env:MB_DUMP  = $dump

$mameArgs = @('apple2p', "-sl$Slot", 'phasor',
    '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
    '-rompath', "$mame\roms", '-inipath', "$mame\ini;$s\ini",
    '-cfg_directory', "$s\cfg", '-nvram_directory', "$s\nvram", '-snapshot_directory', "$s\snap",
    '-state_directory', "$s\sta", '-diff_directory', "$s\diff", '-comment_directory', "$s\comments",
    '-flop1', $copy, '-autoboot_script', "$here\basic_test.lua")
$p = Start-Process -PassThru -WindowStyle Hidden -WorkingDirectory $s "$mame\mame.exe" -ArgumentList $mameArgs
if (-not $p.WaitForExit(600000)) { Stop-Process -Id $p.Id -Force; throw 'MAME timed out' }
if (-not (Test-Path $log)) { throw 'MAME exited without writing a log' }

$check = @("$here\check_basic.py", $log, $Expect)
if (Test-Path $dump) { $check += @('--dump', $dump) }
& $py @check
exit $LASTEXITCODE
