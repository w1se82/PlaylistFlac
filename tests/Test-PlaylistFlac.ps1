# Controles voor de ontwikkelaar. Draait met Windows PowerShell 5.1 en pwsh 7:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-PlaylistFlac.ps1
# Raakt je eigen data\ niet aan: alles gebeurt in een tijdelijke map.
# Met -ZonderServer slaat hij het starten van de webinterface over.

param([switch]$ZonderServer)

$ErrorActionPreference = 'Stop'
$Project = Split-Path $PSScriptRoot
$AppSrc = Join-Path $Project 'app'
$script:Fails = 0
$script:Count = 0

function Check($name, $got, $want) {
    $script:Count++
    if ("$got" -ceq "$want") { return }
    $script:Fails++
    Write-Host "FOUT  $name" -ForegroundColor Red
    Write-Host "      kreeg:    $got"
    Write-Host "      verwacht: $want"
}

# --- 1. alle scripts: geen syntaxfouten, puur ASCII ---------------------------

$scripts = @(Get-ChildItem (Join-Path $AppSrc 'PlaylistFlac.ps1')) + @(Get-ChildItem (Join-Path $AppSrc 'lib') -Filter '*.ps1') +
           @(Get-ChildItem $PSScriptRoot -Filter '*.ps1')
foreach ($f in $scripts) {
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    Check "syntax $($f.Name)" (@($errs).Count) 0
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    Check "ascii $($f.Name)" (@($bytes | Where-Object { $_ -gt 127 }).Count) 0
}

# Elk onderdeel in $LibParts bestaat, en elk bestand in app\lib staat in $LibParts.
$mainText = [IO.File]::ReadAllText((Join-Path $AppSrc 'PlaylistFlac.ps1'))
if ($mainText -notmatch '(?s)\$LibParts = (.+?)\r?\nforeach') { throw 'Geen $LibParts in PlaylistFlac.ps1' }
$parts = @([regex]::Matches($Matches[1], "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
$onDisk = @(Get-ChildItem (Join-Path $AppSrc 'lib') -Filter '*.ps1' | ForEach-Object { $_.BaseName }) | Sort-Object
Check 'LibParts = app\lib' (($parts | Sort-Object) -join ',') ($onDisk -join ',')

# --- 2. de onderdelen inladen met een tijdelijke data-map ----------------------

$Tmp = Join-Path ([IO.Path]::GetTempPath()) "pf-test-$PID"
New-Item -ItemType Directory -Force $Tmp | Out-Null
try {
    # dezelfde variabelen als bovenin PlaylistFlac.ps1, maar alles in $Tmp
    $OnWin = ($PSVersionTable.PSEdition -ne 'Core') -or [bool]$IsWindows
    $OnMac = [bool]$IsMacOS
    $AppDir = $AppSrc; $MainScript = Join-Path $AppSrc 'PlaylistFlac.ps1'; $LibDir = Join-Path $AppSrc 'lib'
    $Root = $Tmp; $UiDir = Join-Path $Project 'ui'
    $DataDir = Join-Path $Tmp 'data'; $StatusDir = Join-Path $DataDir 'status'; $BinDir = Join-Path $Tmp 'bin'
    $Exe = Join-Path $BinDir 'sockseek.exe'; $Ini = Join-Path $DataDir 'instellingen.ini'
    $IniExample = Join-Path $AppSrc 'instellingen.voorbeeld.ini'; $UiFile = Join-Path $Project 'index.html'
    $LogFile = Join-Path $StatusDir 'laatste-run.log'; $Utf8 = New-Object System.Text.UTF8Encoding($false)
    $Ports = 47821..47830; $Version = '0.0.0-test'; $UpdateRepo = 'x/y'
    $AnaScript = Join-Path $AppSrc 'analyse\analyse.py'; $AnaDir = Join-Path $DataDir 'analyse'
    $AnaPy = Join-Path $AnaDir 'venv\Scripts\python.exe'; $AnaReady = Join-Path $AnaDir 'klaar.txt'
    $ExportDir = Join-Path $DataDir 'export'
    function Say($text, $color = 'Gray') { }
    foreach ($part in $parts) { . (Join-Path $LibDir "$part.ps1") }

    # bestandsnamen van Soulseek, ook met tekens die [IO.Path] in PS 5.1 weigert
    Check 'RemoteStem quote' (Get-RemoteStem '@@user\Music\Artist - "Title" (Extended Mix).flac') 'Artist - "Title" (Extended Mix)'
    Check 'RemoteExt pipe' (Get-RemoteExt 'C:/a|b/Track | Edit.mp3') '.mp3'
    Check 'RemoteExt geen' (Get-RemoteExt 'folder/zonderpunt') ''
    Check 'RemoteName' (Get-RemoteName 'a\b/c.flac') 'c.flac'

    $s = Split-Title 'Fluppe - Original Mix'
    Check 'Split-Title base' $s.Base 'Fluppe'
    Check 'Split-Title versie' $s.Version 'Original Mix'
    $s = Split-Title 'Dont Mess (Extended Mix)'
    Check 'Split-Title haakjes' "$($s.Base)|$($s.Version)" 'Dont Mess|Extended Mix'

    Check 'FileVersion haakjes' (Get-FileVersion 'x\Kaufmann - Fluppe (Extended Mix) [www.dj-promo.org].flac' 'Fluppe') 'extended mix'

    Check 'Safe-FileName' (Safe-FileName 'AC/DC: "Live"? ') 'AC_DC_ _Live__'
    Check 'Quote-Arg simpel' (Quote-Arg 'abc') 'abc'
    Check 'Quote-Arg spatie' (Quote-Arg 'a b') '"a b"'

    Check 'versie nieuwer' (Compare-AppVersion '1.4.0' '1.3.5-beta') 1
    Check 'versie beta ouder' (Compare-AppVersion '1.4.0-beta' '1.4.0') -1
    Check 'versie gelijk' (Compare-AppVersion 'v1.3.5-beta' '1.3.5-beta') 0

    # rondleiding: onthouden, niet dubbel, rare namen weigeren, terugzetten
    Check 'rondleiding leeg' (@((Read-Rondleiding).seen).Count) 0
    [void](Update-Rondleiding ([pscustomobject]@{ seen = 'kies-versie' }))
    [void](Update-Rondleiding ([pscustomobject]@{ seen = 'kies-versie' }))
    [void](Update-Rondleiding ([pscustomobject]@{ seen = '../../etc' }))
    $r = Read-Rondleiding
    Check 'rondleiding een keer' (@($r.seen) -join ',') 'kies-versie'
    [void](Update-Rondleiding ([pscustomobject]@{ off = $true }))
    Check 'rondleiding uit' (Read-Rondleiding).off 'True'
    [void](Update-Rondleiding ([pscustomobject]@{ reset = $true }))
    $r = Read-Rondleiding
    Check 'rondleiding reset' "$(@($r.seen).Count) $($r.off)" '0 False'

    # bijwerken: bestanden vervangen, data\ en app\bin weigeren
    $new = Join-Path $Tmp 'nieuw'; $work = Join-Path $Tmp 'werk'
    New-Item -ItemType Directory -Force (Join-Path $new 'app\lib'), $work | Out-Null
    [IO.File]::WriteAllText((Join-Path $new 'index.html'), 'nieuw')
    [IO.File]::WriteAllText((Join-Path $new 'app\lib\x.ps1'), '# x')
    [IO.File]::WriteAllText((Join-Path $Tmp 'index.html'), 'oud')
    Install-UpdateFiles $new $work
    Check 'update vervangt' ([IO.File]::ReadAllText((Join-Path $Tmp 'index.html'))) 'nieuw'
    Check 'update voegt toe' (Test-Path (Join-Path $Tmp 'app\lib\x.ps1')) 'True'
    New-Item -ItemType Directory -Force (Join-Path $new 'data') | Out-Null
    [IO.File]::WriteAllText((Join-Path $new 'data\instellingen.ini'), 'x')
    $refused = $false
    try { Install-UpdateFiles $new $work } catch { $refused = $true }
    Check 'update weigert data\' $refused 'True'
} finally {
    Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 3. de webinterface starten vanuit een kopie ------------------------------

function Get-Url($url) {
    $req = [Net.WebRequest]::Create($url); $req.Timeout = 5000
    try { $res = $req.GetResponse() } catch [Net.WebException] { $res = $_.Exception.Response; if (-not $res) { throw } }
    $sr = New-Object IO.StreamReader($res.GetResponseStream())
    $o = @{ Code = [int]$res.StatusCode; Type = $res.ContentType; Body = $sr.ReadToEnd() }
    $res.Close(); return $o
}
function Post-Json($url, $json) {
    $req = [Net.WebRequest]::Create($url); $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 5000
    $b = [Text.Encoding]::UTF8.GetBytes($json); $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Close()
    $res = $req.GetResponse(); $sr = New-Object IO.StreamReader($res.GetResponseStream()); $t = $sr.ReadToEnd(); $res.Close(); return $t
}

$busy = $false
foreach ($p in 47821..47830) { try { [void](Get-Url "http://localhost:$p/ping.gif"); $busy = $true } catch { } }
if ($ZonderServer) {
    Write-Host 'Webinterface overgeslagen (-ZonderServer).' -ForegroundColor DarkGray
} elseif ($busy) {
    Write-Host 'Webinterface overgeslagen: PlaylistFlac draait al. Sluit hem en probeer opnieuw.' -ForegroundColor Yellow
} else {
    $stage = Join-Path ([IO.Path]::GetTempPath()) "pf-server-$PID"
    New-Item -ItemType Directory -Force (Join-Path $stage 'app\bin') | Out-Null
    Copy-Item (Join-Path $Project 'index.html') $stage
    Copy-Item (Join-Path $Project 'ui') (Join-Path $stage 'ui') -Recurse
    Copy-Item (Join-Path $AppSrc 'PlaylistFlac.ps1'), (Join-Path $AppSrc 'instellingen.voorbeeld.ini') (Join-Path $stage 'app')
    Copy-Item (Join-Path $AppSrc 'lib') (Join-Path $stage 'app\lib') -Recurse
    # een leeg sockseek-bestand, zodat hij niet 115 MB gaat downloaden
    [IO.File]::WriteAllText((Join-Path $stage 'app\bin\sockseek.exe'), '')
    $ps = (Get-Process -Id $PID).Path
    $hidden = if ($IsLinux -or $IsMacOS) { @{} } else { @{ WindowStyle = 'Hidden' } }   # -WindowStyle bestaat alleen op Windows
    $proc = Start-Process $ps -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $stage 'app\PlaylistFlac.ps1'), '-Stil' -PassThru @hidden
    try {
        $base = $null
        for ($i = 0; $i -lt 40 -and -not $base; $i++) {
            Start-Sleep -Milliseconds 250
            foreach ($p in 47821..47830) { try { [void](Get-Url "http://localhost:$p/ping.gif"); $base = "http://localhost:$p" ; break } catch { } }
        }
        Check 'server start' ([bool]$base) 'True'
        if ($base) {
            $r = Get-Url "$base/"
            Check 'GET /' "$($r.Code) $($r.Body -match 'ui/app.js')" '200 True'
            foreach ($f in 'app.css', 'app.js', 'rondleiding.js') {
                $r = Get-Url "$base/ui/$f"
                Check "GET /ui/$f" $r.Code 200
            }
            Check 'GET /ui/onbekend.js' (Get-Url "$base/ui/onbekend.js").Code 404
            Check 'GET /ui/../app/x' (Get-Url "$base/ui/..%2Fapp%2FPlaylistFlac.ps1").Code 404
            $st = (Get-Url "$base/api/state").Body | ConvertFrom-Json
            Check 'state niet ingesteld' $st.setup.ready 'False'
            Check 'state rondleiding' (@($st.rondleiding.seen).Count) 0
            $t = Post-Json "$base/api/rondleiding" '{"seen":"kies-versie"}' | ConvertFrom-Json
            Check 'POST rondleiding' (@($t.seen) -join ',') 'kies-versie'
            $st = (Get-Url "$base/api/state").Body | ConvertFrom-Json
            Check 'rondleiding bewaard' (@($st.rondleiding.seen) -join ',') 'kies-versie'
            [void](Post-Json "$base/api/quit" '{}')
        }
        [void]$proc.WaitForExit(8000)
        Check 'server stopt' $proc.HasExited 'True'
        Check 'geen snelkoppeling-vlag (-Stil)' (Test-Path (Join-Path $stage 'data\status\snelkoppeling.txt')) 'False'
    } finally {
        if (-not $proc.HasExited) { $proc.Kill() }
        Start-Sleep -Milliseconds 300
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$color = if ($script:Fails) { 'Red' } else { 'Green' }
Write-Host ("{0} van {1} controles goed." -f ($script:Count - $script:Fails), $script:Count) -ForegroundColor $color
exit $script:Fails
