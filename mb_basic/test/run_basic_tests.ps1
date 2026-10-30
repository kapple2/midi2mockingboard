# Regression run for the Applesoft & MPLAY command: build MPLAY, put it on a throwaway DOS 3.3 disk
# (in the Windows temp folder) and check in MAME that the Apple II plays what src\tune\tune2mbf.py
# compiles, and what the .MBF file on the disk says. About a minute.
#   run_basic_tests.ps1 [-Mbf <folder with the converted .MBF files>]
param([string]$Mbf)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path "$here\..\..\..").Path
if (-not $Mbf) { $Mbf = "$root\mbf_out" }
$py  = "$root\.venv\Scripts\python.exe"
$acx = 'C:\bin\acx.exe'
$run = "$here\run_basic_test.ps1"
$t   = Join-Path $env:TEMP 'mb_basic_test'
New-Item -ItemType Directory -Force $t | Out-Null

& cmd /c "`"$root\src\mb_basic\build.bat`"" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'MPLAY build failed' }
$arty = "$Mbf\Arty - Hope (Original Mix).MBF"
if (-not (Test-Path $arty)) { throw "missing $arty" }

$disk = "$t\test.dsk"
Copy-Item "$root\src\mb_disk\dos33blank.dsk" $disk -Force
& cmd /c "`"$acx`" -p `"$disk`" MPLAY B 0x8C00 < `"$root\src\mb_basic\build\MPLAY.bin`"" | Out-Null
& cmd /c "`"$acx`" -p `"$disk`" ARTY B 0x6000 < `"$arty`"" | Out-Null

function Tune($name, $text) {
    # the text goes in a file: an empty argument would be dropped on the command line
    Set-Content "$t\$name.txt" $text -NoNewline
    & $py "$root\src\tune\tune2mbf.py" -o "$t\$name.MBF" -f "$t\$name.txt" | Out-Null
    return "$t\$name.MBF"
}

$failed = @()
function Check($name, [scriptblock]$test) {
    Write-Host "--- $name"
    & $test 2>&1 | Select-String -Pattern 'PASS|FAIL|RAM|writes compared|timing|screen' | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { $script:failed += $name }
}

$scale = 'T120 O4 L8 CDEFGAB>C4 / O3 C2 G2 C1'
Check 'tune: two voices, scale and chords' {
    & $run -Disk $disk -Play "& MPLAY `"!$scale`"" -Expect (Tune 'scale' $scale) }

# every command: sharps, flats, dots, rests, tempo, volume, octave limits, lengths, six voices and a seventh that is ignored
$rich = 'T90 O5 L16 C#D-EF+G.A4. R8 B>C<B R T200 V8 O0 C1 O7 B#2 / T150 V15 O2 L8 CDEFGAB / L1 R O3 G / V3 O4 C4C4C4C4 / T255 L64 CCCCCCCC / O1 V9 L2. A / O4 CDE'
Check 'tune: every command, 6 voices, a 7th ignored' {
    & $run -Disk $disk -Play "& MPLAY `"!$rich`"" -Expect (Tune 'rich' $rich) }

Check 'tune: empty' {
    & $run -Disk $disk -Play '& MPLAY "!"' -Expect (Tune 'empty' '') }

# a tune longer than the buffer: 15 notes of 9 seconds each overflow the 8 KB
$long = 'T32 L1. C C C C C C C C C C C C C C C C C C C C'
Check 'tune: longer than the buffer, cut off and silenced' {
    & $run -Disk $disk -Play "& MPLAY `"!$long`"" -Expect (Tune 'long' $long) }

Check 'file: & MPLAY "ARTY" loads the .MBF from the disk' {
    & $run -Disk $disk -Lines '10 & MPLAY "ARTY"|20 PRINT "FIN";"ISHED"|RUN' -Expect $arty }

# The DEMO program on the real disk (src\disk\mb.dsk, made by build_disk.py): it joins two strings, so this
# also checks that & MPLAY takes a string variable.
$real = "$root\src\disk\mb.dsk"
if (Test-Path $real) {
    $demo = 'T120 O4 L4 CCGGAAG2 FFEEDDC2 GGFFEED2 GGFFEED2 CCGGAAG2 FFEEDDC2 / O3 L2 CGFC GCFC GCFC GCFC'
    Check 'disk: RUN DEMO on src\disk\mb.dsk' {
        & $run -Disk $real -Lines 'RUN DEMO|PRINT "FIN";"ISHED"' -Expect (Tune 'demo' $demo) }
    # PLAYMBF asks for a file name, then plays that DOS file 
    Check 'disk: RUN PLAYMBF, then the Arty file' {
        & $run -Disk $real -Lines 'RUN PLAYMBF|~ARTY - HOPE ORIGINAL MIX.MBF|PRINT "FIN";"ISHED"' -Expect $arty }

}

if ($failed) { Write-Host "FAILED: $($failed -join '; ')"; exit 1 }
Write-Host 'All & MPLAY tests passed.'
