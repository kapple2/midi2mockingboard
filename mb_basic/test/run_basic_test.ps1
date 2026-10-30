# Boot a DOS 3.3 disk in MAME (headless, Phasor card), type BASIC lines, and check the music
# that the Apple II plays against the expected .MBF file.
#   run_basic_test.ps1 -Disk <disk.dsk> -Play '& MPLAY "NAME"' -Expect <file.MBF> [-Stream]
#   run_basic_test.ps1 -Disk <disk.dsk> -Lines '10 & MPLAY "NAME"|20 PRINT "FIN";"ISHED"|RUN' -Expect <file.MBF>
# MAME state goes under <project>\mame\; the disk is mounted as a copy in the Windows temp folder.
# -Play is one statement typed in immediate mode (the test adds the line that prints FINISHED);
# -Lines is a complete list of lines, separated by |, that must end by printing FINISHED. A line that
# starts with ~ answers a running program's INPUT. BRUN MPLAY is typed first, unless -Menu or -NoInstall.
#   -Stream   the song comes from the disk: the refill pauses are checked (every song file, not a "!tune")
#   -Keys     press A (a blip over the music) -SfxAt seconds after the first note, ESC 5 s later; use & MPLAY "..",2
#   -Loop     ESC at -SfxAt seconds; use & MPLAY "..",1 (the song must start again by itself)
#   -NoCard   no Mockingboard in the machine: & MPLAY must raise I/O ERROR
#   -ExpectBad  the file is not an MBF: & MPLAY must raise FILE TYPE MISMATCH and write no notes
#   -Menu     the disk's own HELLO menu runs at boot; -Lines answer it
#   -Hangul   the disk is the K-HANGEUL / KBASIC one (hi-res text screen): the test types the lines blind and
#             waits for POKE 800,66 instead of the word FINISHED, and checks that the Hangul font, KBASIC and
#             the CHRGET patch are unchanged afterwards.
param(
    [Parameter(Mandatory)][string]$Disk,
    [string]$Play,
    [string]$Lines,
    [Parameter(Mandatory)][string]$Expect,      # the .MBF file the Apple II should play
    [ValidateRange(1, 7)][int]$Slot = 5,
    [switch]$Stream,
    [switch]$Keys,
    [switch]$Loop,
    [double]$SfxAt = 3,
    [switch]$NoCard,
    [switch]$ExpectBad,
    [switch]$Menu,
    [switch]$NoInstall,
    [switch]$Hangul
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
$done = if ($Hangul) { 'POKE 800,66' } else { 'PRINT "FIN";"ISHED"' }
if (-not $Lines) {
    # an error ends the rest of a typed line, so after a statement that must fail the finish goes on its own line
    $Lines = if ($NoCard -or $ExpectBad) { "$Play|$done" } else { "$Play`: $done" }
}
foreach ($v in 'MB_HANGUL', 'MB_MENU', 'MB_SEND') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
if ($Hangul) { $env:MB_HANGUL = '1' }
if ($Menu) { $env:MB_MENU = '1' }
if ($Keys) { $env:MB_SEND = "${SfxAt}:A," + ($SfxAt + 5) + ':ESC' }
if ($Loop) { $env:MB_SEND = "${SfxAt}:ESC" }
$env:MB_LOG   = $log
$env:MB_LINES = if ($Menu -or $NoInstall) { $Lines } else { 'BRUN MPLAY|' + $Lines }
$env:MB_DONE  = 'FINISHED'
$env:MB_SLOT  = "$Slot"
$env:MB_DUMP  = $dump
if ($env:MB_MAX_SECONDS_PS) { $env:MB_MAX_SECONDS = $env:MB_MAX_SECONDS_PS }
$env:MB_LBL   = "$root\src\mb_basic\build\MPLAY.lbl"

$card = if ($NoCard) { @() } else { @("-sl$Slot", 'phasor') }
$mameArgs = @('apple2p') + $card + @(
    '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
    '-rompath', "$mame\roms", '-inipath', "$mame\ini;$s\ini",
    '-cfg_directory', "$s\cfg", '-nvram_directory', "$s\nvram", '-snapshot_directory', "$s\snap",
    '-state_directory', "$s\sta", '-diff_directory', "$s\diff", '-comment_directory', "$s\comments",
    '-flop1', $copy, '-autoboot_script', "$here\basic_test.lua")
$p = Start-Process -PassThru -WindowStyle Hidden -WorkingDirectory $s "$mame\mame.exe" -ArgumentList $mameArgs
if (-not $p.WaitForExit(900000)) { Stop-Process -Id $p.Id -Force; throw 'MAME timed out' }
if (-not (Test-Path $log)) { throw 'MAME exited without writing a log' }

$check = @("$here\check_log.py", $log, $Expect)
if ($Loop) { $check = @("$here\check_loop.py", $log, $Expect) }
elseif ($Keys) { $check += '--keys' }
if ($NoCard) { $check += '--nocard' } elseif ($ExpectBad) { $check += '--bad' }
if ($Stream) { $check += '--stream' }
if ($Hangul) { $check += '--hangul' }
if (Test-Path $dump) { $check += @('--dump', $dump) }
$ErrorActionPreference = 'Continue'     # the checker reports a failure on stderr and exits 1: pass that on
& $py @check
exit $LASTEXITCODE
