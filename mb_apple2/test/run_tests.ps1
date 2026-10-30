# Regression run for the Apple II driver: rebuild the player, build a disk from the
# converted songs, and check it in MAME with a Phasor card (Mockingboard mode).
#   run_tests.ps1 [-Mbf <folder with the converted .MBF files>]
# Needs Arty, chpn-p24, game-background-T.AMOS.Bliss, HotelCalifornia and mozart-k333 as .MBF
# (made by midi2mbf.bat). Takes about six minutes. The disk is src\disk\mb.dsk, with all five songs as files in the catalog

param([string]$Mbf)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path "$here\..\..\..").Path
if (-not $Mbf) { $Mbf = "$root\mbf_out" }
$py   = "$root\.venv\Scripts\python.exe"
$disk = "$root\src\disk\mb.dsk"
$run  = "$here\run_test.ps1"

$files = @('Arty - Hope (Original Mix).MBF', 'chpn-p24.MBF', 'game-background-T.AMOS.Bliss.MBF', 'HotelCalifornia.MBF',
           'mozart-piano-sonata-k333-movement1.MBF')
foreach ($f in $files) { if (-not (Test-Path "$Mbf\$f")) { throw "missing $Mbf\$f" } }
$arty, $chopin, $bliss, $hotel, $mozart = $files | ForEach-Object { "$Mbf\$_" }

& cmd /c "`"$root\src\mb_apple2\build.bat`"" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'player build failed' }
& cmd /c "`"$root\src\mb_basic\build.bat`"" | Out-Null          # MPLAY and DEMO go on the disk too
if ($LASTEXITCODE -ne 0) { throw 'MPLAY build failed' }
& $py "$root\src\mb_disk\build_disk.py" $disk $arty $chopin $bliss $hotel $mozart | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'disk build failed' }

# A second disk, in the temp folder, whose "songs" are not valid MBF files:
# 1 = plain text, 2 = a real song with its tick rate patched down to 10 Hz (the driver needs 16-255).
$bad = Join-Path $env:TEMP 'mb_bad_songs'
New-Item -ItemType Directory -Force $bad | Out-Null
Set-Content "$bad\1 JUNK.MBF" 'this is not a mockingboard file at all, just text' -NoNewline
$bytes = [IO.File]::ReadAllBytes($arty); $bytes[4] = 10
[IO.File]::WriteAllBytes("$bad\2 SLOW.MBF", $bytes)
$badDisk = Join-Path $env:TEMP 'mb_bad.dsk'
& $py "$root\src\mb_disk\build_disk.py" $badDisk "$bad\1 JUNK.MBF" "$bad\2 SLOW.MBF" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'bad-song disk build failed' }

$failed = @()
function Check($name, [scriptblock]$test) {
    Write-Host "--- $name"
    & $test 2>&1 | Select-String -Pattern 'PASS|FAIL|^ - |refill gaps|first note' | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { $script:failed += $name }
}

Check 'song 1 (Arty), load, plays in full'      { & $run -Disk $disk -Song 1 -Mbf $arty }
Check 'song 2 (Chopin), load, plays in full'    { & $run -Disk $disk -Song 2 -Mbf $chopin }
Check 'song 5 (Mozart, 84 sectors), load, plays in full' { & $run -Disk $disk -Song 5 -Mbf $mozart }
Check 'song 2 (Chopin), stream, plays in full'  { & $run -Disk $disk -Song 2 -Mbf $chopin -PlayMode stream }
Check 'song 3 (Bliss, 129 sectors, drums), stream, refills the ring twice' { & $run -Disk $disk -Song 3 -Mbf $bliss -PlayMode stream }
Check 'song 4 (Hotel California, 171 sectors), stream, refills the ring four times' { & $run -Disk $disk -Song 4 -Mbf $hotel -PlayMode stream }
Check 'song 5 (Mozart), stream, fits the ring, no refill' { & $run -Disk $disk -Song 5 -Mbf $mozart -PlayMode stream }
Check 'song 1 (Arty), stream, starts again when it ends (STREAM_RESTART)' { & $run -Disk $disk -Song 1 -Mbf $arty -PlayMode stream -Loop -SfxAt 27 }
Check 'sound effect, channels idle (load)'      { & $run -Disk $disk -Song 1 -Mbf $arty -Keys }
Check 'sound effect over busy channels (stream)' { & $run -Disk $disk -Song 3 -Mbf $bliss -Keys -SfxAt 33.95 -PlayMode stream }
Check 'sound effect while streaming'            { & $run -Disk $disk -Song 4 -Mbf $hotel -Keys -PlayMode stream }
foreach ($slot in 4, 7, 1) {
    Check "card in slot $slot"                  { & $run -Disk $disk -Song 1 -Mbf $arty -Slot $slot }
}
Check 'no card'                                 { & $run -Disk $disk -Song 1 -Mbf $arty -NoCard }
Check 'bad song: not an MBF file'               { & $run -Disk $badDisk -Song 1 -Mbf $arty -ExpectBad }
Check 'bad song: tick rate below 16 Hz'         { & $run -Disk $badDisk -Song 2 -Mbf $arty -ExpectBad }

if ($failed) { Write-Host "FAILED: $($failed -join '; ')"; exit 1 }
Write-Host 'All Apple II driver tests passed.'
