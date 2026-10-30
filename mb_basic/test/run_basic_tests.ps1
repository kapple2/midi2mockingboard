# Regression run for the resident player MPLAY (the Applesoft & MPLAY command): rebuild it, build the
# real disk src\dist\mb.dsk from the converted songs, and check in MAME (headless, Phasor card in Mockingboard
# mode) that the Apple II plays what the .MBF files and tune2mbf.py say. If the K-HANGEUL / KBASIC disk is
# there, the same player is checked on it, with the Hangul driver and KBASIC loaded. About 20 minutes.
#   run_basic_tests.ps1 [-Mbf <folder with the converted .MBF files>] [-Kbasic <KBASIC.DSK>] [-Khangeul <K-HANGEUL.DSK>] [-Only <part of a check's name>]
# Needs Arty, chpn-p24, game-background-T.AMOS.Bliss, HotelCalifornia and mozart-k333 as .MBF
# (made by midi2mbf.bat). Throwaway disks go in the Windows temp folder.
param([string]$Mbf, [string]$Kbasic = 'D:\dev\proj-apple2\proj-apple2-korean-basic\src\dsk\KBASIC.DSK',
      [string]$Khangeul = 'D:\dev\proj-apple2\proj-apple2-korean-high-resolution\DIST-github\disk\K-HANGEUL.DSK',
      [string]$Only)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path "$here\..\..\..").Path
if (-not $Mbf) { $Mbf = "$root\mbf_out" }
$py   = "$root\.venv\Scripts\python.exe"
$run  = "$here\run_basic_test.ps1"
$t    = Join-Path $env:TEMP 'mb_basic_test'
New-Item -ItemType Directory -Force $t | Out-Null

$files = @('Arty - Hope (Original Mix).MBF', 'chpn-p24.MBF', 'game-background-T.AMOS.Bliss.MBF', 'HotelCalifornia.MBF',
           'mozart-piano-sonata-k333-movement1.MBF')
foreach ($f in $files) { if (-not (Test-Path "$Mbf\$f")) { throw "missing $Mbf\$f" } }
$arty, $chopin, $bliss, $hotel, $mozart = $files | ForEach-Object { "$Mbf\$_" }

& cmd /c "`"$root\src\mb_basic\build.bat`"" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'MPLAY build failed' }
$disk = "$root\src\dist\mb.dsk"                       # the real disk
& $py "$root\src\mb_disk\build_disk.py" $disk $arty $chopin $bliss $hotel $mozart | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'disk build failed' }

# A second disk whose "songs" are not valid MBF files:
# 1 = plain text, 2 = a real song with its tick rate patched down to 10 Hz (the driver needs 16-255).
$bad = Join-Path $t 'bad_songs'
New-Item -ItemType Directory -Force $bad | Out-Null
Set-Content "$bad\1 JUNK.MBF" 'this is not a mockingboard file at all, just text' -NoNewline
$bytes = [IO.File]::ReadAllBytes($arty); $bytes[4] = 10
[IO.File]::WriteAllBytes("$bad\2 SLOW.MBF", $bytes)
$badDisk = Join-Path $t 'mb_bad.dsk'
& $py "$root\src\mb_disk\build_disk.py" $badDisk "$bad\1 JUNK.MBF" "$bad\2 SLOW.MBF" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'bad-song disk build failed' }

function Tune($name, $text, $slots = 4) {
    # the text goes in a file: an empty argument would be dropped on the command line
    Set-Content "$t\$name.txt" $text -NoNewline
    & $py "$root\src\tune\tune2mbf.py" -o "$t\$name.MBF" -f "$t\$name.txt" --ring-slots $slots | Out-Null
    return "$t\$name.MBF"
}

$failed = @()
function Check($name, [scriptblock]$test) {
    if ($Only -and $name -notlike "*$Only*") { return }
    Write-Host "--- $name"
    $ErrorActionPreference = 'Continue'     # a failing check prints "FAIL" on stderr: record it, do not stop
    & $test 2>&1 | Select-String -Pattern 'PASS|FAIL|^ - |refill gaps|ring at|timing|Hangul|effect|restarted' | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { $script:failed += $name }
}
# the catalog names are what build_disk.py makes of the file names
$names = @{ $arty = 'ARTY - HOPE ORIGINAL MIX.MBF'; $chopin = 'CHPN-P24.MBF'; $bliss = 'GAME-BACKGROUND-T.AMOS.BLI.MBF';
            $hotel = 'HOTELCALIFORNIA.MBF'; $mozart = 'MOZART-PIANO-SONATA-K333-M.MBF' }
function Play($file, $flags) { $f = if ($flags) { ",$flags" } else { '' }; return '& MPLAY "' + $names[$file] + '"' + $f }

# --- the songs on the real disk, streamed from their catalog files ---------------------------------
Check 'Arty plays in full'                { & $run -Disk $disk -Play (Play $arty) -Expect $arty -Stream }
Check 'Chopin plays in full'              { & $run -Disk $disk -Play (Play $chopin) -Expect $chopin -Stream }
Check 'Mozart plays in full'              { & $run -Disk $disk -Play (Play $mozart) -Expect $mozart -Stream }
Check 'Bliss plays in full (drums)'       { & $run -Disk $disk -Play (Play $bliss) -Expect $bliss -Stream }
Check 'Hotel California plays in full'    { & $run -Disk $disk -Play (Play $hotel) -Expect $hotel -Stream }
Check 'Arty starts again when it ends (,1)' { & $run -Disk $disk -Play (Play $arty 1) -Expect $arty -Stream -Loop -SfxAt 27 }
Check 'sound effect, channels idle (,2)'  { & $run -Disk $disk -Play (Play $arty 2) -Expect $arty -Stream -Keys }
Check 'sound effect over busy channels'   { & $run -Disk $disk -Play (Play $bliss 2) -Expect $bliss -Stream -Keys -SfxAt 33.95 }
Check 'sound effect while streaming'      { & $run -Disk $disk -Play (Play $hotel 2) -Expect $hotel -Stream -Keys }
foreach ($slot in 4, 7, 1) {
    Check "card in slot $slot"            { & $run -Disk $disk -Play (Play $arty) -Expect $arty -Stream -Slot $slot }
}
# --- the ring size: & MPLAY n moves HIMEM and sets how many 512-byte slots the song ring has ----------------
# (the check also compares the ring's contents at the first note with the first bytes of the file, so it sees the size)
$chopinPlay = Play $chopin
Check 'ring: 2 slots (the minimum)'       { & $run -Disk $disk -Lines ('& MPLAY 2|' + $chopinPlay + ': PRINT "FIN";"ISHED"') -Expect $chopin -Stream }
Check 'ring: 8 slots'                     { & $run -Disk $disk -Lines ('& MPLAY 8|' + $chopinPlay + ': PRINT "FIN";"ISHED"') -Expect $chopin -Stream }
Check 'ring: 28 slots (the maximum), no refill'      { & $run -Disk $disk -Lines ('& MPLAY 28|' + $chopinPlay + ': PRINT "FIN";"ISHED"') -Expect $chopin -Stream }
Check 'ring: HIMEM after BRUN is $7100'   { & $run -Disk $disk -Play 'PRINT "HI";PEEK (116)' -Expect $arty -ExpectError 'HI113' }
Check 'ring: HIMEM follows & MPLAY 8'     { & $run -Disk $disk -Play '& MPLAY 8: PRINT "HI";PEEK (116)' -Expect $arty -ExpectError 'HI105' }
Check 'ring: 1 slot is ILLEGAL QUANTITY'  { & $run -Disk $disk -Play '& MPLAY 1' -Expect $arty -ExpectError 'ILLEGAL QUANTITY' }
Check 'ring: 29 slots is ILLEGAL QUANTITY' { & $run -Disk $disk -Play '& MPLAY 29' -Expect $arty -ExpectError 'ILLEGAL QUANTITY' }
Check 'ring: after a string exists, OUT OF MEMORY' { & $run -Disk $disk -Play 'A$ = "AB" + "CD": & MPLAY 6' -Expect $arty -ExpectError 'OUT OF MEMORY' }
Check 'no card: I/O ERROR'      { & $run -Disk $disk -Play (Play $arty) -Expect $arty -NoCard }
Check 'bad song: not an MBF file'         { & $run -Disk $badDisk -Play '& MPLAY "1 JUNK.MBF"' -Expect $arty -ExpectBad }
Check 'bad song: tick rate below 16 Hz'   { & $run -Disk $badDisk -Play '& MPLAY "2 SLOW.MBF"' -Expect $arty -ExpectBad }

# --- the programs on the disk ------------------------------------------------------------------------
Check 'HELLO menu: song 1'                { & $run -Disk $disk -Menu -Lines '1|~~ |~0|PRINT "FIN";"ISHED"' -Expect $arty -Stream }
$demo = 'T120 O4 L4 CCGGAAG2 FFEEDDC2 GGFFEED2 GGFFEED2 CCGGAAG2 FFEEDDC2 / O3 L2 CGFC GCFC GCFC GCFC'
Check 'RUN DEMO (a tune in a string variable)' { & $run -Disk $disk -NoInstall -Lines 'RUN DEMO|PRINT "FIN";"ISHED"' -Expect (Tune 'demo' $demo) }
Check 'RUN PLAYMBF, then the Arty file'   { & $run -Disk $disk -NoInstall -Lines 'RUN PLAYMBF|~ARTY - HOPE ORIGINAL MIX.MBF|PRINT "FIN";"ISHED"' -Expect $arty -Stream }

# --- tunes: the player compiles the text exactly as tune2mbf.py does ---------------------------------
$scale = 'T120 O4 L8 CDEFGAB>C4 / O3 C2 G2 C1'
Check 'tune: two voices, scale and chords' { & $run -Disk $disk -Play "& MPLAY `"!$scale`"" -Expect (Tune 'scale' $scale) }
# every command: sharps, flats, dots, rests, tempo, volume, octave limits, lengths, six voices and a seventh that is ignored
$rich = 'T90 O5 L16 C#D-EF+G.A4. R8 B>C<B R T200 V8 O0 C1 O7 B#2 / T150 V15 O2 L8 CDEFGAB / L1 R O3 G / V3 O4 C4C4C4C4 / T255 L64 CCCCCCCC / O1 V9 L2. A / O4 CDE'
Check 'tune: every command, 6 voices, a 7th ignored' { & $run -Disk $disk -Play "& MPLAY `"!$rich`"" -Expect (Tune 'rich' $rich) }
Check 'tune: empty'                       { & $run -Disk $disk -Play '& MPLAY "!"' -Expect (Tune 'empty' '') }
# a tune longer than the buffer: 20 whole notes of 9 seconds overflow the 1.8 KB the 4-slot ring leaves
$long = 'T32 L1. C C C C C C C C C C C C C C C C C C C C'
Check 'tune: longer than the buffer, cut off and silenced' { & $run -Disk $disk -Play "& MPLAY `"!$long`"" -Expect (Tune 'long' $long) }
Check 'tune: the same with a ring of 8 slots (3.8 KB)' { & $run -Disk $disk -Lines ('& MPLAY 8|& MPLAY "!' + $long + '": PRINT "FIN";"ISHED"') -Expect (Tune 'long8' $long 8) }
$prog = 'NEW|10 A$ = "!' + $scale + '": & MPLAY A$|20 PRINT "FIN";"ISHED"|RUN'
Check 'tune in a string variable, inside a program' { & $run -Disk $disk -Lines $prog -Expect (Tune 'scale' $scale) }

# --- the K-HANGEUL / KBASIC disk ---------------------------------------------------------------------
if (Test-Path $Kbasic) {
    $kdisk = Join-Path $t 'kbasic_mb.dsk'
    & $py "$root\src\mb_disk\build_disk.py" $kdisk $arty $chopin --base $Kbasic | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'KBASIC disk build failed' }
    Check 'KBASIC disk: Chopin streams, Hangul driver untouched' {
        & $run -Disk $kdisk -Hangul -Play (Play $chopin) -Expect $chopin -Stream }
    Check 'KBASIC disk: ring of 8 slots, Chopin' {
        & $run -Disk $kdisk -Hangul -Lines ('& MPLAY 8|' + $chopinPlay + ': POKE 800,66') -Expect $chopin -Stream }
    Check 'KBASIC disk: a tune' { & $run -Disk $kdisk -Hangul -Play "& MPLAY `"!$scale`"" -Expect (Tune 'scale' $scale) }
}
else { Write-Host "(no ${Kbasic}: the KBASIC checks are skipped)" }

# TYPE (the Hangul text command) installs first and MPLAY last; each & word must reach its own routine
if (Test-Path $Khangeul) {
    $hdisk = Join-Path $t 'khangeul_mb.dsk'
    & $py "$root\src\mb_disk\build_disk.py" $hdisk $arty --base $Khangeul | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'K-HANGEUL disk build failed' }
    Check 'K-HANGEUL disk: BRUN TYPE, BRUN MPLAY, & TYPE then & MPLAY' {
        & $run -Disk $hdisk -Hangul -NoInstall -Stream -Expect $arty `
            -Lines ('BRUN TYPE|BRUN MPLAY|& TYPE,"SAMPLE1"|' + (Play $arty) + ': POKE 800,66') }
}
else { Write-Host "(no ${Khangeul}: the TYPE check is skipped)" }

if ($failed) { Write-Host "FAILED: $($failed -join '; ')"; exit 1 }
Write-Host 'All & MPLAY tests passed.'
