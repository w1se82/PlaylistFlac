# PlaylistFlac - houdt Spotify-playlists bij als FLAC-map, via Soulseek.
# Copyright (c) 2026 WiWi Audio
#
# Elke keer dat je dit start:
#   1. leest het de playlists uit instellingen.ini
#   2. haalt het per playlist de actuele tracklijst op bij Spotify
#   3. zoekt het de nieuwe nummers op Soulseek en laat het per nummer zien
#      welke versies er zijn (Extended Mix, Original Mix, Radio Edit, ...)
#   4. downloadt het de gekozen versies
#
# Wat al binnen is staat in data\status\<playlist-id>.keuzes.json. Met
# versie-kiezen = uit doet sockseek alles zelf en houdt het
# data\status\<playlist-id>.index.csv bij; beide tellen als "al binnen".
#
# Indeling:
#   index.html  de interface; los openen start de tool via playlistflac://
#   app\        dit script, Start.cmd, sockseek (app\bin)
#   data\       instellingen.ini en status; blijft staan bij een update van app\
#
# Zonder opties start de webinterface in je browser. Zoeken en downloaden
# draaien dan als apart proces (-Taak) dat zijn voortgang in
# data\status\taak.json zet; de pagina leest die uit.
#
# Opties (voor de opdrachtregel):
#   -Console   de oude werkwijze in dit venster, zonder browser
#   -Proef     (met -Console) zoekt en laat de versies zien, downloadt niets
#   -Inpakken  maakt PlaylistFlac.zip om te delen, zonder jouw wachtwoorden
#   -Link      gestart via playlistflac:// (index.html); opent zelf geen tabblad
#   -Afmelden  haalt de playlistflac://-koppeling weer uit Windows
#   -Rekordbox maakt data\rekordbox.xml uit de Traktor-collectie (zie Export-Rekordbox)
#
# Analyse (optioneel, vanaf 1.1.0): app\analyse\analyse.py bepaalt BPM, beatgrid,
# cues en key en schrijft een Traktor-playlist (.nml) en een rekordbox.xml naar
# data\export. Python met PyTorch komt in data\analyse (installeren via de
# interface). De muziekbestanden zelf worden alleen gelezen.

[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Console,
    [switch]$Proef,
    [switch]$Inpakken,
    [string]$Taak,
    [switch]$Link,
    [switch]$Afmelden,
    [switch]$Rekordbox,
    [string]$SpotifyLogin,   # intern: wacht op de terugkeer van "Inloggen met Spotify"
    [int]$UiPort
)

$ErrorActionPreference = 'Stop'
# Windows draait dit met Windows PowerShell 5.1, een Mac met PowerShell 7 (pwsh).
# $IsWindows en $IsMacOS bestaan pas vanaf PowerShell 6; in 5.1 zijn ze leeg.
$OnWin = ($PSVersionTable.PSEdition -ne 'Core') -or [bool]$IsWindows
$OnMac = [bool]$IsMacOS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# sockseek schrijft UTF-8; zonder dit worden accenten in bestandsnamen rommel
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$AppDir    = $PSScriptRoot
$Root      = Split-Path $AppDir
$DataDir   = Join-Path $Root 'data'
$BinDir    = Join-Path $AppDir 'bin'
$StatusDir = Join-Path $DataDir 'status'
$Exe       = Join-Path $BinDir $(if ($OnWin) { 'sockseek.exe' } else { 'sockseek' })
$Ini       = Join-Path $DataDir 'instellingen.ini'
$IniExample = Join-Path $AppDir 'instellingen.voorbeeld.ini'
$UiFile    = Join-Path $Root 'index.html'
$LogFile   = Join-Path $StatusDir 'laatste-run.log'
$Utf8      = New-Object System.Text.UTF8Encoding($false)
$Ports     = 47821..47830
$Version   = '1.3.4-beta'     # ook in README.md; de interface leest hem uit /api/state
$UpdateRepo = 'w1se82/PlaylistFlac'     # hier haalt de updateknop nieuwe versies vandaan
# analyse: het script staat in app\analyse, Python met PyTorch per computer in data\analyse
$AnaScript = Join-Path (Join-Path $AppDir 'analyse') 'analyse.py'
$AnaDir    = Join-Path $DataDir 'analyse'
$AnaPy     = if ($OnWin) { Join-Path $AnaDir 'venv\Scripts\python.exe' } else { Join-Path $AnaDir 'venv/bin/python' }
$AnaReady  = Join-Path $AnaDir 'klaar.txt'
$ExportDir = Join-Path $DataDir 'export'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

# --- Windows of Mac ---------------------------------------------------------
# (Linux is niet officieel ondersteund, maar handig om te testen.)

function Open-Linux($target) {
    if (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $target } else { Say "Open zelf: $target" Yellow }
}

# Een webadres in de standaardbrowser.
function Open-Url($url) {
    if ($OnWin) { Start-Process $url } elseif ($OnMac) { & open $url } else { Open-Linux $url }
}

# Een map in Verkenner of Finder.
function Open-Folder($dir) {
    if ($OnWin) { Start-Process explorer.exe (Quote-Arg $dir) } elseif ($OnMac) { & open $dir } else { Open-Linux $dir }
}

# Een bestand aanwijzen in Verkenner of Finder.
function Show-File($path) {
    if ($OnWin) { Start-Process explorer.exe "/select,`"$path`"" } elseif ($OnMac) { & open -R $path } else { Open-Linux (Split-Path $path) }
}

# Een tekstbestand openen om te bewerken (Kladblok of TextEdit).
function Open-Editor($path) {
    if ($OnWin) { Start-Process notepad.exe $path } elseif ($OnMac) { & open -e $path } else { Say "Open $path in een teksteditor." Yellow }
}

# Start dit script nog een keer als apart proces, zonder venster.
function Start-Self([string]$ArgText) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path        # powershell.exe of pwsh
    $policy = if ($OnWin) { '-ExecutionPolicy Bypass ' } else { '' }
    $psi.Arguments = "-NoProfile $policy-File " + (Quote-Arg $PSCommandPath) + " $ArgText"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($psi)
}

# --- inpakken -------------------------------------------------------------

# Zip met Unix-rechten erin, zodat Start.command op een Mac na het uitpakken
# uitvoerbaar is (Compress-Archive kan dat niet). Alles onder $stage gaat mee.
function Write-ReleaseZip($stage, $zip) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $toInt = { param([uint32]$u) [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0) }
    $exec = & $toInt (0x81ED * 65536)      # gewoon bestand, rwxr-xr-x (0100755)
    $plain = & $toInt (0x81A4 * 65536)     # gewoon bestand, rw-r--r-- (0100644)
    $fs = [IO.File]::Open($zip, 'CreateNew')
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $rel = $f.FullName.Substring($stage.TrimEnd('\').Length + 1) -replace '\\', '/'
            $e = $za.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
            $e.LastWriteTime = $f.LastWriteTime
            $e.ExternalAttributes = $(if ($f.Extension -eq '.command') { $exec } else { $plain })
            $out = $e.Open(); $in = [IO.File]::OpenRead($f.FullName)
            try { $in.CopyTo($out) } finally { $in.Dispose(); $out.Dispose() }
        }
    } finally { $za.Dispose(); $fs.Dispose() }
    # .NET schrijft "gemaakt op MS-DOS"; dan negeert macOS de rechten. Op Unix zetten.
    $b = [IO.File]::ReadAllBytes($zip)
    $eocd = -1
    for ($i = $b.Length - 22; $i -ge 0; $i--) { if ([BitConverter]::ToUInt32($b, $i) -eq 0x06054b50) { $eocd = $i; break } }
    if ($eocd -lt 0) { throw 'Zip zonder einde?' }
    $n = [BitConverter]::ToUInt16($b, $eocd + 10)
    $pos = [int][BitConverter]::ToUInt32($b, $eocd + 16)
    for ($k = 0; $k -lt $n; $k++) {
        if ([BitConverter]::ToUInt32($b, $pos) -ne 0x02014b50) { throw 'Onverwachte zip-indeling.' }
        $b[$pos + 5] = 3
        $pos += 46 + [BitConverter]::ToUInt16($b, $pos + 28) + [BitConverter]::ToUInt16($b, $pos + 30) + [BitConverter]::ToUInt16($b, $pos + 32)
    }
    [IO.File]::WriteAllBytes($zip, $b)
}

if ($Inpakken) {
    # in release\ van de projectmap; die map zelf gaat niet mee in de zip
    $releaseDir = Join-Path $Root 'release'
    New-Item -ItemType Directory -Force $releaseDir | Out-Null
    $zip = Join-Path $releaseDir "PlaylistFlac-$Version.zip"
    # via een tijdelijke kopie, zodat bin (115 MB) en data (wachtwoord) er niet in komen
    $stage = Join-Path ([IO.Path]::GetTempPath()) "PlaylistFlac-inpakken-$PID"
    $pkg = Join-Path $stage 'PlaylistFlac'
    New-Item -ItemType Directory -Force (Join-Path $pkg 'app') | Out-Null
    Copy-Item (Join-Path $Root 'index.html'), (Join-Path $Root 'README.md') $pkg
    $docs = Join-Path $Root 'docs'
    if (Test-Path $docs) { Copy-Item $docs (Join-Path $pkg 'docs') -Recurse }
    Copy-Item (Join-Path $AppDir 'PlaylistFlac.ps1'), (Join-Path $AppDir 'Start.cmd'), (Join-Path $AppDir 'Start.command'), $IniExample (Join-Path $pkg 'app')
    New-Item -ItemType Directory -Force (Join-Path $pkg 'app\analyse') | Out-Null
    Copy-Item (Join-Path $AppDir 'analyse\analyse.py'), (Join-Path $AppDir 'analyse\model.json') (Join-Path $pkg 'app\analyse')
    Write-ReleaseZip $stage $zip
    Remove-Item $stage -Recurse -Force
    Say "Klaar: $zip" Green
    Say 'Zonder data\ en app\bin - je wachtwoord en je status zitten er niet in.'
    return
}

# --- instellingen ---------------------------------------------------------

function Read-Settings($path) {
    $s = @{}
    $lists = New-Object System.Collections.ArrayList
    $inLists = $false
    foreach ($raw in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[playlists\]$') { $inLists = $true; continue }
        if ($inLists) {
            # "Mapnaam = link" of alleen "link". Een link kan zelf '=' bevatten (?si=).
            if ($line -match '^(?<name>[^=]+?)\s*=\s*(?<src>(https?://|spotify:|[A-Za-z]:\\|~|/).+)$' -and
                $Matches.name -notmatch '^(https?:|spotify:)') {
                [void]$lists.Add(@{ Name = $Matches.name.Trim(); Source = $Matches.src.Trim() })
            } else {
                [void]$lists.Add(@{ Name = $null; Source = $line })
            }
        } elseif ($line -match '^(?<k>[\w-]+)\s*=\s*(?<v>.*)$') {
            $s[$Matches.k.ToLower()] = $Matches.v.Trim()
        }
    }
    $s['playlists'] = $lists
    return $s
}

function Expand-Home($p) {
    if ($p -match '^~') { $p = $HOME + $p.Substring(1) }
    # "~\Music" uit de standaardinstellingen is op een Mac "~/Music"
    if (-not $OnWin) { $p = $p -replace '\\', '/' }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Is-Yes($v) { return "$v" -match '^(ja|j|yes|y|true|1)$' }

# Leest instellingen.ini in de script-variabelen $cfg, $Mode, $Prefs, $MusicDir
# en $HasSpotifyApp, en schrijft de sockseek-config. Geeft een foutmelding
# terug als er iets ontbreekt, anders $null.
function Load-Config {
    New-Item -ItemType Directory -Force $StatusDir | Out-Null
    if (-not (Test-Path $Ini)) { Copy-Item $IniExample $Ini }
    $script:cfg = Read-Settings $Ini
    $defaults = @{
        'alleen-flac'     = 'ja'
        'tim-selector'    = 'nee'
        'nette-namen'     = 'ja'
        'versie-kiezen'   = 'vragen'
        'voorkeur-versie' = 'extended, original, club'
        'muziekmap'       = '~\Music'
    }
    foreach ($k in $defaults.Keys) { if (-not $cfg[$k]) { $cfg[$k] = $defaults[$k] } }
    $script:Mode = $cfg['versie-kiezen'].ToLower()
    $script:Prefs = @($cfg['voorkeur-versie'] -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $script:MusicDir = Expand-Home $cfg['muziekmap']
    $script:HasSpotifyApp = [bool]($cfg['spotify-id'] -and $cfg['spotify-secret'])
    New-Item -ItemType Directory -Force $StatusDir | Out-Null
    Write-SockseekConf

    if ($Mode -notin 'vragen', 'automatisch', 'uit') {
        return "versie-kiezen = $Mode snap ik niet; kies vragen, automatisch of uit."
    }
    if (-not $cfg['soulseek-gebruiker'] -or -not $cfg['soulseek-wachtwoord']) {
        return 'Vul eerst een Soulseek-naam en -wachtwoord in.'
    }
    return $null
}

# Past waarden in instellingen.ini aan zonder het commentaar weg te gooien.
# $values: hashtable met sleutel = waarde; $playlists: lijst van @{Name; Source},
# of $null om de playlists te laten staan.
function Write-Settings($values, $playlists) {
    $lines = New-Object Collections.ArrayList
    $seen = @{}
    $inLists = $false
    foreach ($raw in [IO.File]::ReadAllLines($Ini, [Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if ($line -match '^\[playlists\]$') {
            foreach ($k in $values.Keys) { if (-not $seen[$k]) { [void]$lines.Add("$k = $($values[$k])"); $seen[$k] = $true } }
            $inLists = $true; [void]$lines.Add($raw); continue
        }
        if ($inLists) {
            if ($null -ne $playlists -and $line -ne '' -and -not $line.StartsWith('#')) { continue }
            [void]$lines.Add($raw); continue
        }
        if ($line -match '^(?<k>[\w-]+)\s*=' -and $values.Contains($Matches.k.ToLower())) {
            $k = $Matches.k.ToLower()
            [void]$lines.Add("$k = $($values[$k])"); $seen[$k] = $true; continue
        }
        [void]$lines.Add($raw)
    }
    if (-not $inLists) {
        foreach ($k in $values.Keys) { if (-not $seen[$k]) { [void]$lines.Add("$k = $($values[$k])") } }
        [void]$lines.Add('[playlists]')
    }
    if ($null -ne $playlists) {
        foreach ($p in $playlists) {
            [void]$lines.Add($(if ($p.Name) { "$($p.Name) = $($p.Source)" } else { $p.Source }))
        }
    }
    [IO.File]::WriteAllLines($Ini, [string[]]$lines, $Utf8)
}

# --- sockseek ophalen als hij er nog niet is ------------------------------

function Install-Sockseek {
    Say 'sockseek (de Soulseek-downloader) ophalen bij GitHub...' Cyan
    $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/fiso64/sockseek/releases/latest'
    $want = if ($OnWin) { '*win-x64.zip' }
            elseif ($OnMac) {
                # Apple-chip (M1 en later) of Intel
                if ("$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" -eq 'Arm64') { '*osx-arm64.tar.gz' } else { '*osx-x64.tar.gz' }
            } else { '*linux-x64.tar.gz' }
    $asset = $rel.assets | Where-Object { $_.name -like $want } | Select-Object -First 1
    if (-not $asset) { throw "Geen sockseek voor deze computer gevonden op GitHub ($want)." }
    New-Item -ItemType Directory -Force $BinDir | Out-Null
    $archive = Join-Path $BinDir $asset.name
    Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $archive
    if ($OnWin) {
        Expand-Archive $archive $BinDir -Force
    } else {
        & tar -xzf $archive -C $BinDir
        if ($LASTEXITCODE) { throw 'sockseek uitpakken mislukte.' }
        # staat hij in een submap, dan naar app/bin zelf
        if (-not (Test-Path $Exe)) {
            $found = Get-ChildItem $BinDir -Recurse -File -Filter 'sockseek' | Select-Object -First 1
            if ($found) { Move-Item -LiteralPath $found.FullName -Destination $Exe -Force }
        }
        & chmod +x $Exe
        if ($OnMac) {
            # macOS start alleen programma's met een (eigen) handtekening; deze is lokaal
            # gedownload en niet in quarantaine, een ad-hoc handtekening is genoeg
            & xattr -d com.apple.quarantine $Exe 2>$null
            & codesign --verify $Exe 2>$null
            if ($LASTEXITCODE) { & codesign --force --sign - $Exe 2>$null }
        }
    }
    Remove-Item $archive
    if (-not (Test-Path $Exe)) { throw 'sockseek staat na het uitpakken niet in app/bin.' }
    Say "sockseek $($rel.tag_name) geinstalleerd." Green
}

# Zonder verbinding blijft sockseek eindeloos opnieuw inloggen; dus eerst kijken.
function Test-Soulseek {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $wait = $tcp.BeginConnect('server.slsknet.org', 2242, $null, $null)
        return ($wait.AsyncWaitHandle.WaitOne(10000) -and $tcp.Connected)
    } catch {
        return $false
    } finally {
        $tcp.Close()
    }
}

$NoSoulseekMsg = 'Kan de Soulseek-server niet bereiken (server.slsknet.org, poort 2242). Geen internet, of een firewall/netwerk (school, werk, VPN) blokkeert Soulseek.'

# --- tracklijsten ---------------------------------------------------------

function Get-SpotifyRef($src) {
    if ($src -match '(?<type>playlist|album)[/:](?<id>[A-Za-z0-9]{22})') {
        return @{ Type = $Matches.type; Id = $Matches.id }
    }
    return $null
}

# Twee bronnen voor een Spotify-tracklijst:
#  - de Web API: de hele playlist, maar alleen na "Inloggen met Spotify" (een
#    eigen developer-app, waarvan het account Premium moet hebben) en alleen voor
#    playlists die van jou zijn of waar je aan meewerkt;
#  - de openbare embed-pagina: zonder account, maar maximaal 100 nummers.
# Get-SpotifyTracks probeert de API en valt anders terug op de embed-pagina.

$SpotifyTokenPath = Join-Path $DataDir 'spotify-token.json'
$SpotifyLoginStatus = Join-Path $StatusDir 'spotify-login.json'
$SpotifyRedirect = 'http://127.0.0.1:48721/callback'
$SpotifyScopes = 'playlist-read-private playlist-read-collaborative'

function Get-SpotifyBasic {
    $pair = "$($cfg['spotify-id']):$($cfg['spotify-secret'])"
    return 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
}

function Read-SpotifyToken {
    if (-not (Test-Path $SpotifyTokenPath)) { return $null }
    try { return [IO.File]::ReadAllText($SpotifyTokenPath, $Utf8) | ConvertFrom-Json } catch { return $null }
}

function Save-SpotifyToken($tok, $old) {
    $saved = [ordered]@{
        access_token  = $tok.access_token
        # Spotify stuurt niet altijd een nieuwe refresh token mee; dan de oude houden
        refresh_token = $(if ($tok.refresh_token) { $tok.refresh_token } elseif ($old) { $old.refresh_token } else { $null })
        expires_at    = (Get-Date).AddSeconds([int]$tok.expires_in - 60).ToString('o')
        user          = $(if ($old) { $old.user } else { $null })
    }
    [IO.File]::WriteAllText($SpotifyTokenPath, ($saved | ConvertTo-Json), $Utf8)
    return [pscustomobject]$saved
}

# Geldige access token, zo nodig ververst; $null als er niet is ingelogd.
function Get-SpotifyAccessToken([switch]$Force) {
    if (-not $HasSpotifyApp) { return $null }
    $tok = Read-SpotifyToken
    if (-not $tok -or -not $tok.refresh_token) { return $null }
    if (-not $Force -and $tok.access_token -and [datetime]$tok.expires_at -gt (Get-Date)) { return $tok.access_token }
    $new = Invoke-RestMethod -Method Post -Uri 'https://accounts.spotify.com/api/token' -UseBasicParsing `
        -Headers @{ Authorization = (Get-SpotifyBasic) } -Body @{ grant_type = 'refresh_token'; refresh_token = $tok.refresh_token }
    return (Save-SpotifyToken $new $tok).access_token
}

function Invoke-SpotifyApi($url) {
    $token = Get-SpotifyAccessToken
    try {
        return Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 401) { throw }
        $token = Get-SpotifyAccessToken -Force
        return Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing
    }
}

function Convert-ApiTrack($it) {
    if (-not $it -or $it.is_local -or ($it.type -and $it.type -ne 'track')) { return }
    $names = @($it.artists | ForEach-Object { $_.name })
    [pscustomobject]@{
        Uri = $it.uri; Artist = $names[0]; Title = $it.name
        Length = [int][math]::Round($it.duration_ms / 1000)
        Artists = ($names -join ', '); Preview = $it.preview_url
    }
}

# Hele playlist of album via de Web API. $null als er niet is ingelogd.
function Get-SpotifyApiTracks($ref) {
    if (-not (Get-SpotifyAccessToken)) { return $null }
    $api = 'https://api.spotify.com/v1'
    $tracks = New-Object Collections.ArrayList
    if ($ref.Type -eq 'playlist') {
        $meta = Invoke-SpotifyApi "$api/playlists/$($ref.Id)?fields=name,images"
        $url = "$api/playlists/$($ref.Id)/items?limit=50"
        while ($url) {
            $page = Invoke-SpotifyApi $url
            # sinds 2026 heet het veld "item"; "track" is het oude
            foreach ($x in $page.items) { $t = Convert-ApiTrack $(if ($x.item) { $x.item } else { $x.track }); if ($t) { [void]$tracks.Add($t) } }
            $url = $page.next
        }
    } else {
        $meta = Invoke-SpotifyApi "$api/albums/$($ref.Id)"
        $url = "$api/albums/$($ref.Id)/tracks?limit=50"
        while ($url) {
            $page = Invoke-SpotifyApi $url
            foreach ($x in $page.items) { $t = Convert-ApiTrack $x; if ($t) { [void]$tracks.Add($t) } }
            $url = $page.next
        }
    }
    $cover = @($meta.images | Sort-Object width | Where-Object { $_.width -ge 200 -or -not $_.width } | Select-Object -First 1).url
    return @{ Name = $meta.name; Tracks = $tracks.ToArray(); Cover = $cover }
}

function Get-SpotifyTracks($ref) {
    $api = $null; $apiError = $null; $embed = $null; $embedError = $null
    if ($HasSpotifyApp -and (Read-SpotifyToken)) {
        try { $api = Get-SpotifyApiTracks $ref } catch {
            $code = $_.Exception.Response.StatusCode.value__
            $apiError = if ($code -in 403, 404) { 'Spotify geeft deze playlist niet via de API: hij is niet van jou en je werkt er niet aan mee.' }
                        else { "Spotify-API: $($_.Exception.Message)" }
        }
    }
    try { $embed = Get-SpotifyEmbedTracks $ref } catch { $embedError = $_.Exception.Message }
    if ($api) {
        # de API geeft geen fragmenten meer; die komen van de embed-pagina (eerste 100)
        if ($embed) {
            $prev = @{}; foreach ($t in $embed.Tracks) { if ($t.Preview) { $prev[$t.Uri] = $t.Preview } }
            foreach ($t in $api.Tracks) { if (-not $t.Preview -and $prev[$t.Uri]) { $t.Preview = $prev[$t.Uri] } }
            if (-not $api.Cover) { $api.Cover = $embed.Cover }
        }
        $api.Full = $true
        return $api
    }
    if (-not $embed) { throw $embedError }
    $embed.Full = $false
    $embed.Note = $apiError
    return $embed
}

# --- inloggen met Spotify (OAuth) ---
# De webinterface start dit als apart proces en opent de Spotify-pagina. Dit
# proces luistert op 127.0.0.1:48721 (de redirect-URL van de app), wisselt de
# code in voor tokens en stuurt de browser terug naar PlaylistFlac.

function Write-LoginStatus($state, $message) {
    $o = [ordered]@{ state = $state; message = $message; at = (Get-Date).ToString('o') }
    [IO.File]::WriteAllText($SpotifyLoginStatus, ($o | ConvertTo-Json -Compress), $Utf8)
}

function Get-SpotifyAuthorizeUrl($state) {
    $q = @{ client_id = $cfg['spotify-id']; response_type = 'code'; redirect_uri = $SpotifyRedirect
            scope = $SpotifyScopes; state = $state; show_dialog = 'true' }
    return 'https://accounts.spotify.com/authorize?' + (($q.Keys | ForEach-Object { "$_=$([Uri]::EscapeDataString($q[$_]))" }) -join '&')
}

# "a=1&b=x%20y" -> @{ a = '1'; b = 'x y' }
function Parse-Query([string]$q) {
    $h = @{}
    foreach ($pair in ($q -split '&')) {
        if (-not $pair) { continue }
        $k, $v = $pair -split '=', 2
        $h[[Uri]::UnescapeDataString(($k -replace '\+', ' '))] = [Uri]::UnescapeDataString((("$v") -replace '\+', ' '))
    }
    return $h
}

function Run-SpotifyLogin($state, $uiPort) {
    [void](Load-Config)
    $back = "http://localhost:$uiPort/"
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 48721)
    try { $listener.Start() } catch {
        Write-LoginStatus 'fout' 'Poort 48721 is bezet, dus Spotify kan niet terugkomen bij PlaylistFlac. Sluit andere programma''s die met Spotify inloggen (zoals sockseek) en probeer opnieuw.'
        return
    }
    Write-LoginStatus 'wachten' 'Wachten tot je bij Spotify toestemming geeft...'
    $deadline = (Get-Date).AddMinutes(5)
    try {
        while ((Get-Date) -lt $deadline) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
                $first = $reader.ReadLine()
                if ($first -notmatch '^GET (?<path>/callback)\?(?<q>\S*) HTTP') {
                    $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($bytes, 0, $bytes.Length); continue
                }
                $q = Parse-Query $Matches.q
                $ok = $false
                if ($q['error']) {
                    $msg = if ($q['error'] -eq 'access_denied') { 'Je hebt bij Spotify op Annuleren geklikt.' } else { "Spotify gaf een fout: $($q['error'])" }
                } elseif ($q['state'] -ne $state) {
                    $msg = 'Deze inlogpoging hoort niet bij PlaylistFlac (verkeerde state). Probeer opnieuw.'
                } else {
                    try {
                        $tok = Invoke-RestMethod -Method Post -Uri 'https://accounts.spotify.com/api/token' -UseBasicParsing `
                            -Headers @{ Authorization = (Get-SpotifyBasic) } `
                            -Body @{ grant_type = 'authorization_code'; code = $q['code']; redirect_uri = $SpotifyRedirect }
                        $saved = Save-SpotifyToken $tok $null
                        $me = Invoke-RestMethod -Uri 'https://api.spotify.com/v1/me' -Headers @{ Authorization = "Bearer $($saved.access_token)" } -UseBasicParsing
                        $saved.user = if ($me.display_name) { $me.display_name } else { $me.id }
                        [IO.File]::WriteAllText($SpotifyTokenPath, ($saved | ConvertTo-Json), $Utf8)
                        $ok = $true
                        $msg = "Ingelogd als $($saved.user)."
                    } catch {
                        $err = try { $_.ErrorDetails.Message | ConvertFrom-Json } catch { $null }
                        $msg = switch ("$($err.error)") {
                            'invalid_client' { 'De Client ID of het Client secret klopt niet. Kopieer ze opnieuw uit de instellingen van je Spotify-app.' }
                            'invalid_grant'  { "Spotify keurde de inlogcode af ($($err.error_description)). Klopt de Redirect URI in je app precies? Probeer anders opnieuw." }
                            default          { "Inloggen lukte niet: $(if ($err.error_description) { $err.error_description } else { $_.Exception.Message })" }
                        }
                    }
                }
                Write-LoginStatus $(if ($ok) { 'ok' } else { 'fout' }) $msg
                $title = if ($ok) { 'Gelukt!' } else { 'Dat ging mis' }
                $html = "<!doctype html><meta charset=utf-8><title>PlaylistFlac</title>" +
                    "<meta http-equiv=refresh content='3;url=$back'>" +
                    "<body style='font:18px system-ui;background:#160f26;color:#f6f1ff;display:grid;place-items:center;height:100vh;margin:0'>" +
                    "<div style='max-width:36em;padding:24px'><h1 style='margin:0 0 12px'>$title</h1><p>$([Net.WebUtility]::HtmlEncode($msg))</p>" +
                    "<p><a style='color:#3ee6ff' href='$back'>Terug naar PlaylistFlac</a></p></div>"
                $body = $Utf8.GetBytes($html)
                $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length); $stream.Write($body, 0, $body.Length)
                return
            } finally {
                $client.Close()
            }
        }
        Write-LoginStatus 'fout' 'Geen antwoord van Spotify binnen 5 minuten. Probeer opnieuw.'
    } finally {
        $listener.Stop()
    }
}

# De openbare embed-pagina geeft naam en tracks zonder Spotify-account,
# maar maximaal 100 nummers.
function Get-SpotifyEmbedTracks($ref) {
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
    $html = $wc.DownloadString("https://open.spotify.com/embed/$($ref.Type)/$($ref.Id)")
    $m = [regex]::Match($html, '<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', 'Singleline')
    if (-not $m.Success) { throw 'Spotify gaf een onverwachte pagina terug.' }
    $entity = ($m.Groups[1].Value | ConvertFrom-Json).props.pageProps.state.data.entity
    $tracks = foreach ($t in $entity.trackList) {
        [pscustomobject]@{
            Uri    = $t.uri
            # subtitle is "Artiest1, Artiest2"; zoeken op de eerste werkt het best
            Artist = ($t.subtitle -split ',\s*')[0].Trim()
            Title  = $t.title
            Length = [int][math]::Round($t.duration / 1000)
            Artists = $t.subtitle -replace ',\s*', ', '
            Preview = $t.audioPreview.url
        }
    }
    $cover = @($entity.coverArt.sources | Sort-Object width | Where-Object { $_.width -ge 200 } | Select-Object -First 1).url
    return @{ Name = $entity.name; Tracks = @($tracks); Cover = $cover }
}

# CSV-export, bijv. van exportify.app ("Track Name", "Artist Name(s)",
# "Duration (ms)") of een eigen lijst met Artist/Title/Length.
function Get-CsvTracks($path) {
    $rows = @(Import-Csv $path -Encoding UTF8)
    if (-not $rows.Count) { return @() }
    $cols = $rows[0].PSObject.Properties.Name
    function Pick($names) { foreach ($n in $names) { if ($cols -contains $n) { return $n } } }
    $cTitle  = Pick 'Track Name', 'Title', 'Name', 'title'
    $cArtist = Pick 'Artist Name(s)', 'Artist', 'Artists', 'artist'
    $cUri    = Pick 'Track URI', 'URI', 'uri'
    $cMs     = Pick 'Duration (ms)', 'duration_ms'
    $cSec    = Pick 'Length', 'length'
    if (-not $cTitle -or -not $cArtist) { throw 'CSV mist een kolom voor titel of artiest.' }
    foreach ($r in $rows) {
        $len = 0
        if ($cMs) { $len = [int][math]::Round([double]$r.$cMs / 1000) }
        elseif ($cSec) { $len = [int]$r.$cSec }
        [pscustomobject]@{
            Uri    = $(if ($cUri -and $r.$cUri) { $r.$cUri } else { "$($r.$cArtist)|$($r.$cTitle)".ToLower() })
            Artist = ($r.$cArtist -split ',\s*')[0].Trim()
            Title  = $r.$cTitle
            Length = $len
            Artists = $r.$cArtist
            Preview = $null
        }
    }
}

function Csv-Field($v) { return '"' + ("$v" -replace '"', '""') + '"' }

function Write-TrackCsv($tracks, $path, [switch]$NoLength) {
    $lines = @($(if ($NoLength) { 'Artist,Title' } else { 'Artist,Title,Length' }))
    $lines += $tracks | ForEach-Object {
        $f = @((Csv-Field $_.Artist), (Csv-Field $_.Title))
        if (-not $NoLength) { $f += $_.Length }
        $f -join ','
    }
    [IO.File]::WriteAllLines($path, [string[]]$lines, $Utf8)
}

function Safe-FileName($name) {
    # wat Windows niet toestaat, ook op een Mac: dan blijven mappen uitwisselbaar
    return ($name -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim(' .')
}

# --- versies herkennen ----------------------------------------------------

$VersionWords = '\b(mix|edit|remix|rmx|version|dub|rework|bootleg|vip|live|instrumental|acapella|cappella|extended|original|club|radio|remaster|remastered|re-?edit|flip|cut)\b'
# woorden die zeggen wat voor versie het is, niet van wie
$GenericWords = 'mix|edit|remix|rmx|version|dub|rework|bootleg|vip|extended|original|club|radio|re-?edit|flip|cut|the|feat|ft|and|vs|x|remaster|remastered|\d{4}'
# woorden die een ander nummer maken dan het origineel
$OtherSongWords = '\b(remix|rmx|rework|bootleg|flip|vip|re-?edit|live|acapella|instrumental)\b'

function Norm($s) {
    return ("$s".ToLowerInvariant() -replace '[''\u2019]', '' -replace '[^\p{L}\p{N}]+', ' ').Trim()
}

# "Nutcase - Mark Eteson Remix" -> Base "Nutcase", Version "Mark Eteson Remix"
function Split-Title($title) {
    $base = $title; $version = ''
    if ($base -match '^(?<b>.+?)\s+-\s+(?<v>.+)$') { $base = $Matches.b; $version = $Matches.v }
    foreach ($m in [regex]::Matches($base, '[\(\[]([^\)\]]*)[\)\]]')) {
        if (-not $version -and $m.Groups[1].Value -match $VersionWords) { $version = $m.Groups[1].Value }
    }
    $base = ($base -replace '\s*[\(\[][^\)\]]*[\)\]]', '').Trim()
    return @{ Base = $base; Version = $version.Trim() }
}

# Naam en extensie van een bestand op Soulseek. Niet via [IO.Path]: die weigert in
# Windows PowerShell tekens als " en | , en die komen op andermans Mac of Linux
# gewoon voor in bestandsnamen.
function Get-RemoteName($path) { return ("$path" -split '[\\/]')[-1] }
function Get-RemoteStem($path) {
    $n = Get-RemoteName $path; $i = $n.LastIndexOf('.')
    if ($i -ge 0) { return $n.Substring(0, $i) } else { return $n }
}
function Get-RemoteExt($path) {
    $n = Get-RemoteName $path; $i = $n.LastIndexOf('.')
    if ($i -ge 0) { return $n.Substring($i) } else { return '' }
}

# Haalt "Extended Mix", "Mark Eteson Remix" e.d. uit een Soulseek-bestandsnaam.
function Get-FileVersion($filename, $base) {
    $name = (Get-RemoteStem $filename) -replace '_', ' '
    # reclame van downloadsites eruit: "[www.dj-promo.org]", "-www.groovytunes.org"
    $name = $name -replace '(?i)\s*-?\s*[\[\(]?\s*www\.[^\s\]\)]+\s*[\]\)]?', '' `
                  -replace '(?i)\s*[\[\(]\s*[a-z0-9-]+\.(org|com|net|ru|info|to|eu|nl|de)\s*[\]\)]', ''
    $parts = @([regex]::Matches($name, '[\(\[]([^\)\]]*)[\)\]]') | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -match $VersionWords -and $_ -notmatch '^\s*(feat|ft|with)\b' })
    if (-not $parts.Count) {
        # zonder haakjes: "artiest-titel-original_mix" of "Titel - Radio Edit":
        # neem wat er na de titel komt
        $flat = Norm $name
        $nb = Norm $base
        $at = $flat.IndexOf($nb)
        if ($at -ge 0) {
            $rest = $flat.Substring($at + $nb.Length).Trim()
            if ($rest -match $VersionWords) { $parts = @($rest) }
        }
    }
    $label = Norm ($parts -join ' ')
    $label = $label -replace '\brmx\b', 'remix' -replace '\b(flac|wav|web|promo|vinyl|cd|\d+ ?(bit|khz|kbps))\b', ''
    $label = ($label -replace '\s+', ' ').Trim()
    if ($label -in 'original', 'extended', 'club') { $label += ' mix' }
    # "X Remix (Extended Mix)" is hetzelfde als "X Extended Remix"
    $label = $label -replace '^(.+) remix extended mix$', '$1 extended remix'
    return $label
}

function Format-Length($sec) {
    if (-not $sec) { return '  ?  ' }
    return '{0}:{1:00}' -f [int][math]::Floor($sec / 60), ($sec % 60)
}

# Groepeert zoekresultaten per versie en zet de beste keuze bovenaan.
function Group-Versions($results, $track) {
    $split = Split-Title $track.Title
    $nb = Norm $split.Base
    $ownWords = @((Norm $split.Version) -split ' ' | Where-Object { $_ -and $_ -notmatch "^($GenericWords)$" })

    # titel moet in de bestandsnaam staan, artiest ergens in het pad (map of naam);
    # spaties tellen niet mee, zodat "A.D.H.S." ook "ADHS" vindt
    $nbFlat = $nb -replace ' ', ''
    # alle artiesten van het nummer tellen mee: bij "Oxia, Space 92" staat soms
    # Space 92 vooraan in de bestandsnaam
    $artistsFlat = @(@($track.Artist) + @("$($track.Artists)" -split ',\s*') |
        ForEach-Object { (Norm $_) -replace ' ', '' } | Where-Object { $_ } | Select-Object -Unique)
    $hits = @($results | Where-Object { ((Norm (($_.File.Filename -split '[\\/]')[-1])) -replace ' ', '').Contains($nbFlat) })
    if (-not $hits.Count) { $hits = @($results) }
    if ($artistsFlat.Count) {
        $withArtist = @($hits | Where-Object {
            $path = (Norm $_.File.Filename) -replace ' ', ''
            @($artistsFlat | Where-Object { $path.Contains($_) }).Count -gt 0
        })
        if ($withArtist.Count) { $hits = $withArtist }
    }

    $groups = [ordered]@{}
    $i = 0
    foreach ($r in $hits) {
        $label = Get-FileVersion $r.File.Filename $split.Base
        if (-not $groups.Contains($label)) {
            $groups[$label] = @{ Label = $label; Results = New-Object System.Collections.ArrayList; Rank = $i }
        }
        [void]$groups[$label].Results.Add($r)
        $i++
    }

    # Een bestand zonder versienaam met (bijna) dezelfde lengte als een benoemde
    # versie is vrijwel zeker die versie: "01 - Fluppe.flac" van 5:55 = de Original Mix.
    if ($groups.Contains('')) {
        $median = {
            param($res)
            $l = @($res | ForEach-Object { $_.File.Length } | Where-Object { $_ } | Sort-Object)
            if ($l.Count) { $l[[int][math]::Floor($l.Count / 2)] } else { 0 }
        }
        $named = @($groups.Values | Where-Object { $_.Label } | ForEach-Object { @{ G = $_; Len = (& $median $_.Results) } })
        $keep = New-Object System.Collections.ArrayList
        foreach ($r in $groups[''].Results) {
            $len = $r.File.Length
            $target = if ($len) {
                $named | Where-Object { $_.Len -and [math]::Abs($_.Len - $len) -le 3 } |
                    Sort-Object { $_.G.Results.Count } -Descending | Select-Object -First 1
            }
            if ($target) { [void]$target.G.Results.Add($r) } else { [void]$keep.Add($r) }
        }
        if ($keep.Count) { $groups[''].Results = $keep } else { $groups.Remove('') }
    }

    $out = foreach ($g in $groups.Values) {
        $score = 0
        if ($ownWords.Count) {
            # Spotify-versie is een remix van iemand: die moet het zijn
            $hit = @($ownWords | Where-Object { " $($g.Label) " -like "* $_ *" }).Count
            if ($hit -eq $ownWords.Count) { $score += 1000 } else { $score -= 1000 }
        } elseif ($g.Label -match $OtherSongWords) {
            $score -= 500
        }
        for ($p = 0; $p -lt $Prefs.Count; $p++) {
            if ($g.Label -like "*$($Prefs[$p])*") { $score += 100 - $p * 10; break }
        }
        $lengths = @($g.Results | ForEach-Object { $_.File.Length } | Where-Object { $_ } | Sort-Object)
        $users = @($g.Results | ForEach-Object { $_.User.Username } | Select-Object -Unique)
        $best = $g.Results[0].File
        $quality = (Get-RemoteExt $best.Filename).TrimStart('.').ToUpper()
        if ($best.BitDepth -and $best.SampleRate) { $quality += " $($best.BitDepth)/$([math]::Round($best.SampleRate / 1000, 1))" }
        elseif ($best.BitRate) { $quality += " $($best.BitRate)" }
        # Bronnen om te proberen: een per gebruiker, eerst wie een vrij uploadslot
        # heeft (anders kom je in een wachtrij), dan de snelste.
        $seenUsers = @{}
        $cands = @()
        $order = 0
        foreach ($r in $g.Results) {
            $order++
            if ($seenUsers[$r.User.Username]) { continue }
            $seenUsers[$r.User.Username] = $true
            $cands += [pscustomobject]@{
                u = $r.User.Username; f = $r.File.Filename; size = $r.File.Size
                free = [bool]$r.User.HasFreeUploadSlot; speed = [double]$r.User.UploadSpeed; order = $order
            }
        }
        $freeCount = @($cands | Where-Object { $_.free }).Count
        $cands = @($cands | Sort-Object @{ e = 'free'; Descending = $true }, @{ e = 'speed'; Descending = $true }, order |
            Select-Object -First 8)
        [pscustomobject]@{
            Label   = $g.Label
            Display = $(if ($g.Label) { (Get-Culture).TextInfo.ToTitleCase($g.Label) } else { '(zonder aanduiding)' })
            Length  = $(if ($lengths.Count) { $lengths[[int][math]::Floor($lengths.Count / 2)] } else { 0 })
            Sources = $users.Count
            Free    = $freeCount
            Quality = $quality
            Score   = $score
            Rank    = $g.Rank
            Candidates = $cands
        }
    }
    return @($out | Sort-Object @{ e = 'Score'; Descending = $true }, @{ e = 'Free'; Descending = $true }, @{ e = 'Sources'; Descending = $true }, Rank)
}

# --- Soulseek -------------------------------------------------------------

function Quote-Arg([string]$a) {
    if ($a -and $a -notmatch '[\s"]') { return $a }
    $a = $a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $a + '"'
}

function Format-Elapsed($since) {
    $s = [int]((Get-Date) - $since).TotalSeconds
    return '{0}:{1:00}' -f [int][math]::Floor($s / 60), ($s % 60)
}

# Voortgang voor de webinterface. Alleen actief in een achtergrondtaak (-Taak);
# daar is $script:TaskState gevuld.
$TaskStatusPath = Join-Path $StatusDir 'taak.json'
$script:TaskState = $null
$script:TaskWritten = $null

function Update-Task($fields, [switch]$Force) {
    if (-not $script:TaskState) { return }
    foreach ($k in $fields.Keys) { $script:TaskState[$k] = $fields[$k] }
    $now = Get-Date
    if (-not $Force -and $script:TaskWritten -and ($now - $script:TaskWritten).TotalMilliseconds -lt 300) { return }
    $script:TaskWritten = $now
    $script:TaskState['updated'] = $now.ToString('o')
    $tmp = "$TaskStatusPath.tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($script:TaskState | ConvertTo-Json -Depth 6 -Compress), $Utf8)
        Move-Item -LiteralPath $tmp -Destination $TaskStatusPath -Force
    } catch { }    # de pagina leest net; de volgende update komt zo
}

function Add-TaskLog($text) {
    if (-not $script:TaskState) { return }
    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $text
    $log = @($script:TaskState['log']) + $line | Where-Object { $_ } | Select-Object -Last 80
    Update-Task @{ log = @($log) } -Force
}

# Start sockseek met --progress-json en leest de uitvoer regel voor regel, zodat
# we voortgang kunnen tonen. Elke halve seconde zonder uitvoer roept het $OnTick
# aan (de klok tikt door). Komt er binnen $StartTimeout seconden geen zoek- of
# downloadactiviteit op gang, of valt het daarna $StallTimeout seconden stil,
# dan wordt sockseek gestopt - anders blijft hij eindeloos opnieuw proberen.
# Een vrije poort voor inkomende Soulseek-verbindingen. De vaste standaardpoort
# geeft "port in use" als er nog een ander sockseek-proces draait.
function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, 0)
    $l.Start()
    $port = $l.LocalEndpoint.Port
    $l.Stop()
    return $port
}

function Invoke-Sockseek($ArgList, [scriptblock]$OnEvent, [scriptblock]$OnTick, [int]$StartTimeout = 60, [int]$StallTimeout = 0) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $all = @($ArgList) + '--progress-json' + '--listen-port' + (Get-FreePort)
    $psi.Arguments = ($all | ForEach-Object { Quote-Arg "$_" }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    [void]$p.StandardError.ReadToEndAsync()      # staat ook in het logbestand

    $lines = New-Object Collections.ArrayList
    $t0 = Get-Date
    $lastActivity = $null
    $timedOut = $null
    $read = $p.StandardOutput.ReadLineAsync()
    while ($true) {
        if ($read.Wait(500)) {
            $line = $read.Result
            if ($null -eq $line) { break }
            if ($line.StartsWith('{"type"')) {
                $ev = ConvertFrom-Json $line
                if ($ev.type -in 'search_start', 'download_start', 'download_progress', 'track_state') { $lastActivity = Get-Date }
                if ($OnEvent) { & $OnEvent $ev }
            } else {
                [void]$lines.Add($line)
            }
            $read = $p.StandardOutput.ReadLineAsync()
        } else {
            if ($OnTick) { & $OnTick }
            $now = Get-Date
            if (-not $lastActivity -and $StartTimeout -and ($now - $t0).TotalSeconds -gt $StartTimeout) { $timedOut = 'start'; break }
            if ($lastActivity -and $StallTimeout -and ($now - $lastActivity).TotalSeconds -gt $StallTimeout) { $timedOut = 'stil'; break }
        }
    }
    if ($timedOut -and -not $p.HasExited) { try { $p.Kill() } catch { } }
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Lines = $lines; TimedOut = $timedOut }
}

# Zoekt alle nummers in een keer (sockseek houdt zich dan zelf aan de
# zoeklimiet van Soulseek) en geeft per nummer de resultaten terug.
function Search-Tracks($tracks, $key) {
    $csv = Join-Path $StatusDir "$key.zoek.csv"
    $searchList = @($tracks | ForEach-Object { [pscustomobject]@{ Artist = $_.Artist; Title = (Split-Title $_.Title).Base } })
    Write-TrackCsv $searchList $csv -NoLength

    $total = $tracks.Count
    $st = @{ Started = 0; Done = 0; Current = ''; T0 = (Get-Date) }
    $show = {
        $busy = Format-Elapsed $st.T0
        if ($st.Started -eq 0) {
            Write-Progress -Activity "Zoeken op Soulseek ($total nummers)" -Status "Inloggen... $busy" -PercentComplete 0
        } else {
            $n = [math]::Max($st.Done, $st.Started - 1)
            Write-Progress -Activity "Zoeken op Soulseek ($total nummers)" `
                -Status "$n van $total klaar  -  $busy bezig" -CurrentOperation "nu: $($st.Current)" `
                -PercentComplete ([math]::Min(100, [int]($n * 100 / $total)))
        }
    }
    $onEvent = {
        param($ev)
        if ($ev.type -eq 'search_start') {
            $st.Started++
            $st.Current = "$($ev.data.artist) - $($ev.data.title)"
            Say ("      zoekt {0,2}/{1}: {2}" -f $st.Started, $total, $st.Current) DarkGray
            if ($st.Started -eq 1) { Add-TaskLog 'Ingelogd op Soulseek' }
            Add-TaskLog ("Zoeken {0}/{1}: {2}" -f $st.Started, $total, $st.Current)
        } elseif ($ev.type -eq 'track_state') {
            $st.Done++
        }
        Update-Task @{ phase = 'zoeken'; done = [math]::Max($st.Done, $st.Started - 1); total = $total; current = $st.Current }
        & $show
    }
    Update-Task @{ phase = 'inloggen'; done = 0; total = $total; current = '' } -Force
    Add-TaskLog "Inloggen op Soulseek als $($cfg['soulseek-gebruiker'])"

    $res = Invoke-Sockseek @($csv, '--input-type', 'csv', '--config', $ConfPath, '--print', 'json-all',
        '--no-skip-existing', '--no-write-index', '--log-file', $LogFile) $onEvent $show -StartTimeout 75 -StallTimeout 300
    Write-Progress -Activity 'Zoeken op Soulseek' -Completed
    if ($res.TimedOut -eq 'start') {
        Add-TaskLog 'Na 75 seconden nog niet ingelogd; gestopt'
        throw 'Inloggen op Soulseek lukt niet. Klopt je naam/wachtwoord? Is de naam misschien al van iemand anders? (zie status\laatste-run.log)'
    }
    if ($res.TimedOut) { throw 'Soulseek reageert al 5 minuten niet meer; verbinding weggevallen?' }
    if ($res.ExitCode -gt 1) { throw "sockseek stopte met foutcode $($res.ExitCode) (zie status\laatste-run.log)." }
    Say "      zoeken klaar in $(Format-Elapsed $st.T0)" DarkGray
    Add-TaskLog "Zoeken klaar in $(Format-Elapsed $st.T0)"

    # een regel JSON per nummer, in dezelfde volgorde als de lijst
    $lines = @($res.Lines | Where-Object { $_ -match '^\s*\[\s*(\{|\])' })
    if ($lines.Count -ne $tracks.Count) {
        throw "sockseek gaf $($lines.Count) resultaatregels voor $($tracks.Count) nummers."
    }
    # PowerShell 5.1 geeft een JSON-array als een geheel terug; foreach pakt hem uit
    $perTrack = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $items = New-Object System.Collections.ArrayList
        foreach ($r in (ConvertFrom-Json $line)) { if ($r) { [void]$items.Add($r) } }
        [void]$perTrack.Add($items.ToArray())
    }
    return , $perTrack
}

function Flat($s) { return (Norm $s) -replace ' ', '' }

# Downloadt de gekozen versies in rondes. Elke ronde is een sockseek-sessie die
# alle openstaande bestanden tegelijk ophaalt, elk bij de volgende bron uit
# zijn lijst. Zo hoef je niet per bron te wachten tot hij opgeeft.
# $picks: lijst van @{ Title; Candidates; File = $null } - File wordt gevuld.
function Download-Picks($picks, $tmpRoot, [int]$Rounds = 4) {
    $total = @($picks).Count
    $st = @{ T0 = (Get-Date); Round = 0; Current = ''; Pct = 0; Status = ''; Size = 0 }
    # bestandsgrootte uit de zoekresultaten: sockseek geeft die niet altijd door
    $sizes = @{}
    $done = { @($picks | Where-Object { $_.File }).Count }
    $show = {
        $d = & $done
        Write-Progress -Activity "Downloaden ($total bestanden)" -Status "$d van $total binnen  -  ronde $($st.Round)  -  $(Format-Elapsed $st.T0)" `
            -CurrentOperation $st.Current -PercentComplete ([math]::Min(100, [int]($d * 100 / [math]::Max(1, $total))))
    }
    $onEvent = {
        param($ev)
        if ($ev.type -eq 'download_start') {
            $st.Current = Get-RemoteStem $ev.data.filename
            $st.Pct = 0; $st.Status = 'downloaden...'
            $st.Size = [double]$sizes[(Flat $st.Current)]
            if (-not $st.Size -and [double]$ev.data.size -gt 1MB) { $st.Size = [double]$ev.data.size }
            $mb = if ($st.Size) { ' ({0:N1} MB)' -f ($st.Size / 1MB) } else { '' }
            Add-TaskLog "Start bij $($ev.data.username): $($st.Current)$mb"
        } elseif ($ev.type -eq 'track_state' -and $ev.data.terminalOutcome -eq 'Failed') {
            $why = switch ("$($ev.data.failureReason)") {
                'AllDownloadsFailed'   { 'bron gaf het bestand niet (offline, wachtrij of geweigerd)' }
                'OutOfDownloadRetries' { 'te vaak onderbroken' }
                'NoSearchResults'      { 'niet meer gevonden bij die bron' }
                default                { "$($ev.data.failureReason)" }
            }
            Add-TaskLog "Mislukt: $($ev.data.title) - $why"
        } elseif ($ev.type -eq 'download_progress') {
            $st.Pct = [double]$ev.data.percent
            $tot = [double]$ev.data.totalBytes
            if ($tot -le 0) { $tot = $st.Size }
            $got = [double]$ev.data.bytesTransferred
            if ($got -le 0 -and $tot -gt 0) { $got = $tot * $st.Pct / 100 }
            if ($st.Pct -le 0 -and $tot -gt 0 -and $got -gt 0) { $st.Pct = [math]::Round($got * 100 / $tot, 1) }
            $st.Status = if ($tot -gt 0) { '{0:N1} / {1:N1} MB' -f ($got / 1MB), ($tot / 1MB) } else { '{0:N1} MB' -f ($got / 1MB) }
        }
        Update-Task @{ file = @{ title = $st.Current; pct = $st.Pct; status = $st.Status } }
        & $show
    }

    for ($round = 0; $round -lt $Rounds; $round++) {
        $active = @($picks | Where-Object { -not $_.File -and @($_.Candidates).Count -gt $round })
        if (-not $active.Count) { break }
        $st.Round = $round + 1
        $dir = Join-Path $tmpRoot "ronde$($round + 1)"
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        New-Item -ItemType Directory -Force $dir | Out-Null

        $list = Join-Path $tmpRoot 'downloads.txt'
        $links = foreach ($p in $active) {
            $c = $p.Candidates[$round]
            if ($c.size) { $sizes[(Flat (Get-RemoteStem $c.f))] = [double]$c.size }
            # sockseek leest dit als URL: zonder deze drie wordt + een spatie, raakt %
            # verminkt en breekt " de regel
            '"slsk://{0}/{1}"' -f $c.u, (($c.f -replace '\\', '/') -replace '%', '%25' -replace '\+', '%2B' -replace '"', '%22')
        }
        # hetzelfde nummer twee keer op de playlist: maar een keer ophalen
        $links = @($links | Select-Object -Unique)
        [IO.File]::WriteAllLines($list, [string[]]$links, $Utf8)
        Say "      ronde $($round + 1): $($active.Count) bestand(en) tegelijk proberen..." DarkGray
        Add-TaskLog "Ronde $($round + 1): $($active.Count) bestand(en) tegelijk proberen"
        Update-Task @{ phase = 'downloaden'; round = $round + 1; done = (& $done); total = $total } -Force

        $res = Invoke-Sockseek @($list, '--input-type', 'list', '--config', $ConfPath, '--output-dir', $dir,
            '--no-write-index', '--log-file', $LogFile) $onEvent $show -StartTimeout 90 -StallTimeout 120
        if ($res.TimedOut -eq 'start') { Add-TaskLog 'Geen enkele bron reageerde binnen 90 seconden' }
        elseif ($res.TimedOut) { Add-TaskLog '2 minuten geen voortgang meer; ronde afgebroken' }

        # bestanden terugkoppelen aan de keuzes via de oorspronkelijke bestandsnaam
        $files = @(Get-ChildItem $dir -Recurse -File |
            Where-Object { $_.Extension -match '^\.(flac|mp3|wav|aiff?|m4a|ogg|alac|opus)$' })
        foreach ($p in $active) {
            $want = Flat (Get-RemoteStem $p.Candidates[$round].f)
            $hit = $files | Where-Object { (Flat $_.BaseName) -eq $want } | Select-Object -First 1
            if ($hit) {
                $p.File = $hit
                $p.Source = "$($p.Candidates[$round].u)|$($p.Candidates[$round].f)"
                Say "      binnen: $($p.Title)" Green
                Add-TaskLog "Binnen: $($p.Title)"
            }
        }
        Add-TaskLog ("Ronde {0} klaar: {1} van {2} binnen" -f ($round + 1), (& $done), $total)
    }
    Write-Progress -Activity 'Downloaden' -Completed
    Update-Task @{ done = (& $done) } -Force
    foreach ($p in @($picks | Where-Object { -not $_.File })) {
        Add-TaskLog "Niet gelukt na $([math]::Min($Rounds, @($p.Candidates).Count)) bron(nen): $($p.Title)"
    }
}

# Verplaatst een download naar de playlistmap met een nette naam en onthoudt
# hem in keuzes.json. Geeft het eindpad terug.
function Save-Download($track, $display, $label, $file, $outDir, $choicesPath) {
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $suffix = if ($label) { " ($display)" } else { '' }
    $target = if (Is-Yes $cfg['nette-namen']) {
        Safe-FileName ("{0} - {1}{2}{3}" -f $track.Artist, (Split-Title $track.Title).Base, $suffix, $file.Extension)
    } else { $file.Name }
    $dest = Join-Path $outDir $target
    $c = 2
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $outDir ('{0} ({1}){2}' -f [IO.Path]::GetFileNameWithoutExtension($target), $c, $file.Extension)
        $c++
    }
    Move-Item -LiteralPath $file.FullName -Destination $dest
    Remember-Choice $track $display $dest $choicesPath
    return $dest
}

# Onthoudt in keuzes.json dat dit nummer binnen is, in dit bestand.
function Remember-Choice($track, $display, $dest, $choicesPath) {
    # bij meerdere versies van hetzelfde nummer: allemaal onthouden
    $choices = Read-Choices $choicesPath
    $prev = $choices[$track.Uri]
    $versie = $display; $bestand = Split-Path $dest -Leaf
    if ($prev -and $prev.status -eq 'binnen') {
        $versie = "$($prev.versie) + $versie"; $bestand = "$($prev.bestand) + $bestand"
    }
    $choices[$track.Uri] = @{ status = 'binnen'; versie = $versie; bestand = $bestand }
    Save-Choices $choices $choicesPath
}

# Zet alle binnengehaalde keuzes op hun plek en geeft het aantal gelukte terug.
# Gaat er bij een bestand iets mis, dan gaat de rest gewoon door: de tijdelijke
# map wordt hierna gewist, dus wat hier niet verplaatst wordt is weg.
function Save-Picks($picks, $outDir, $choicesPath) {
    $ok = 0
    $moved = @{}      # tijdelijk pad -> @{ Dest; Source }
    foreach ($p in $picks) {
        if (-not $p.File) {
            Say "   mislukt, volgende keer opnieuw: $($p.Title)" Yellow
            Add-TaskLog "Niet gelukt: $($p.Title)"
            continue
        }
        try {
            $from = $p.File.FullName
            $done = $moved[$from]
            if (-not $done) {
                $dest = Save-Download $p.Track $p.Group.Display $p.Group.Label $p.File $outDir $choicesPath
                $moved[$from] = @{ Dest = $dest; Source = $p.Source }
            } elseif ($done.Source -eq $p.Source) {
                # twee Spotify-uitgaven van hetzelfde nummer, zelfde bestand: een is genoeg
                Remember-Choice $p.Track $p.Group.Display $done.Dest $choicesPath
                Add-TaskLog "Staat dubbel op de playlist, een bestand is genoeg: $($p.Title)"
            } else {
                throw 'een ander nummer gebruikte dezelfde bestandsnaam'
            }
            $ok++
        } catch {
            Say "   niet opgeslagen: $($p.Title) - $($_.Exception.Message)" Yellow
            Add-TaskLog "Niet opgeslagen: $($p.Title) - $($_.Exception.Message)"
        }
    }
    return $ok
}

# --- sockseek-config (zodat het wachtwoord niet op de opdrachtregel staat) --

$ConfPath = Join-Path $StatusDir 'sockseek.conf'

function Write-SockseekConf {
    $conf = @(
        "username = $($cfg['soulseek-gebruiker'])"
        "password = $($cfg['soulseek-wachtwoord'])"
    )
    if (Is-Yes $cfg['tim-selector']) {
        # Tim Selector: mp3, en dan alleen 320 kbps; bestanden zonder bekende
        # bitrate vallen af, anders glipt er toch een 128 kbps tussendoor
        $conf += 'format = mp3', 'pref-format = mp3', 'min-bitrate = 320', 'strict-conditions = true'
    } else {
        $conf += 'pref-format = flac'
        if (Is-Yes $cfg['alleen-flac']) { $conf += 'format = flac' }
    }
    if ($Mode -eq 'uit' -and (Is-Yes $cfg['nette-namen'])) {
        $conf += 'name-format = {sartist( - )stitle|slsk-filename}'
    }
    if ($HasSpotifyApp) {
        $conf += "spotify-id = $($cfg['spotify-id'])"
        $conf += "spotify-secret = $($cfg['spotify-secret'])"
    }
    # alleen schrijven als er iets veranderd is: een lopende taak leest dit bestand
    $text = ($conf -join "`r`n") + "`r`n"
    if ((Test-Path $ConfPath) -and [IO.File]::ReadAllText($ConfPath, $Utf8) -eq $text) { return }
    [IO.File]::WriteAllText($ConfPath, $text, $Utf8)
}

# --- status per playlist --------------------------------------------------

function Read-Choices($path) {
    $h = @{}
    if (Test-Path $path) {
        $obj = [IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    }
    return $h
}

function Save-Choices($h, $path) {
    [IO.File]::WriteAllText($path, ($h | ConvertTo-Json -Depth 4), $Utf8)
}

# Nummers die sockseek (versie-kiezen = uit) al binnen heeft gehaald
function Read-IndexDone($path) {
    $h = @{}
    if (Test-Path $path) {
        Import-Csv $path -Encoding UTF8 | Where-Object { $_.state -in '1', '3' } |
            ForEach-Object { $h["$($_.artist)|$($_.title)".ToLower()] = $true }
    }
    return $h
}

# Wat staat er al in de playlistmap? Zowel de muziekbestanden als een
# _index.csv die sockseek daar bij eerdere downloads achterliet.
function Get-FolderIndex($outDir) {
    $fi = @{ Files = @(); Index = @{} }
    if (-not (Test-Path -LiteralPath $outDir)) { return $fi }
    $fi.Files = @(Get-ChildItem -LiteralPath $outDir -Recurse -Depth 1 -File |
        Where-Object { $_.Extension -match '^\.(flac|mp3|wav|aiff?|m4a|ogg|alac|opus)$' } |
        ForEach-Object { @{ Name = $_.Name; Flat = (Flat $_.BaseName) } })
    $old = Join-Path $outDir '_index.csv'
    if (Test-Path -LiteralPath $old) {
        foreach ($r in (Import-Csv -LiteralPath $old -Encoding UTF8)) {
            if ($r.state -notin '1', '3') { continue }
            $file = Split-Path $r.filepath -Leaf
            # alleen als het bestand er nog staat
            if ($file -and (Test-Path -LiteralPath (Join-Path $outDir $file))) {
                $fi.Index["$($r.artist)|$($r.title)".ToLower()] = $file
            }
        }
    }
    return $fi
}

# Geeft de bestandsnaam terug als dit nummer al in de map lijkt te staan.
# Op titel zonder versie + een van de artiesten, dus een andere versie van
# hetzelfde nummer telt ook ("Opnieuw kiezen" zet dat terug).
function Find-InFolder($track, $fi) {
    $hit = $fi.Index["$($track.Artist)|$($track.Title)".ToLower()]
    if ($hit) { return $hit }
    $split = Split-Title $track.Title
    $base = Flat $split.Base
    if ($base.Length -lt 2) { return $null }
    $artists = @(@($track.Artist) + @("$($track.Artists)" -split ',\s*') |
        ForEach-Object { Flat $_ } | Where-Object { $_ } | Select-Object -Unique)
    # remix van iemand ("Opal - Four Tet Remix"): die naam moet er ook in staan,
    # anders is het origineel ("BICEP - Opal.flac") een ander nummer
    $own = @((Norm $split.Version) -split ' ' | Where-Object { $_ -and $_ -notmatch "^($GenericWords)$" })
    foreach ($f in $fi.Files) {
        if (-not $f.Flat.Contains($base)) { continue }
        if (@($own | Where-Object { -not $f.Flat.Contains($_) }).Count) { continue }
        foreach ($a in $artists) { if ($f.Flat.Contains($a)) { return $f.Name } }
    }
    return $null
}

# Schrijft <playlist>.m3u8 in de playlistmap: het playlistformaat dat
# rekordbox, Serato, Engine DJ, VirtualDJ, djay, Mixxx en Traktor allemaal lezen.
# Op Spotify-volgorde; wat verder nog in de map staat komt onderaan.
# Schrijft alleen als er iets veranderd is. Geeft het aantal nummers terug.
function Write-PlaylistM3u($info, $outDir) {
    if (-not (Test-Path -LiteralPath $outDir)) { return 0 }
    $choices = Read-Choices (Join-Path $StatusDir "$($info.Key).keuzes.json")
    $folder = Get-FolderIndex $outDir
    $here = @{}
    Get-ChildItem -LiteralPath $outDir -File | Where-Object { $_.Extension -match '^\.(flac|mp3|wav|aiff?|m4a|ogg|alac|opus)$' } |
        ForEach-Object { $here[$_.Name.ToLower()] = $_.Name }
    $used = @{}
    $lines = New-Object Collections.ArrayList
    [void]$lines.Add('#EXTM3U')
    [void]$lines.Add("#PLAYLIST:$($info.Name)")
    foreach ($t in $info.Tracks) {
        $c = $choices[$t.Uri]
        $files = @()
        if ($c -and $c.status -eq 'binnen' -and $c.bestand) { $files = @("$($c.bestand)" -split ' \+ ') }
        elseif (-not $c) { $f = Find-InFolder $t $folder; if ($f) { $files = @($f) } }
        foreach ($f in $files) {
            $name = $here[$f.ToLower()]
            if (-not $name -or $used[$name]) { continue }
            $used[$name] = $true
            # lengte -1 (onbekend): het bestand is vaak een andere versie dan op Spotify
            $who = if ($t.Artists) { $t.Artists -replace ',\s*', ', ' } else { $t.Artist }
            [void]$lines.Add("#EXTINF:-1,$who - $($t.Title)")
            [void]$lines.Add($name)
        }
    }
    foreach ($name in ($here.Values | Sort-Object)) {
        if ($used[$name]) { continue }
        [void]$lines.Add("#EXTINF:-1,$([IO.Path]::GetFileNameWithoutExtension($name))")
        [void]$lines.Add($name)
    }
    $path = Join-Path $outDir ((Safe-FileName $info.Name) + '.m3u8')
    $text = ($lines -join "`r`n") + "`r`n"
    if (-not (Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path, $Utf8) -ne $text) {
        [IO.File]::WriteAllText($path, $text, $Utf8)
    }
    return ($lines.Count - 2) / 2
}

# Bestanden uit een .m3u8 (in volgorde), als volledige paden die bestaan.
function Read-M3u($path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $dir = Split-Path $path
    return @([IO.File]::ReadAllLines($path, $Utf8) | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
        $p = if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $dir $_ }
        if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).FullName }
    })
}

# --- versies kiezen en downloaden ---------------------------------------

function Sync-WithChoice($tracks, $key, $outDir) {
    $choicesPath = Join-Path $StatusDir "$key.keuzes.json"
    $choices = Read-Choices $choicesPath
    $indexDone = Read-IndexDone (Join-Path $StatusDir "$key.index.csv")
    $folder = Get-FolderIndex $outDir
    $pending = @($tracks | Where-Object {
        $c = $choices[$_.Uri]
        if ($c -and $c.status -ne 'opnieuw') { return $false }
        if (-not $c -and $indexDone["$($_.Artist)|$($_.Title)".ToLower()]) { return $false }
        if (-not $c -and (Find-InFolder $_ $folder)) { return $false }
        $true
    })
    $skipped = @($choices.Values | Where-Object { $_.status -eq 'overgeslagen' }).Count
    if (-not $pending.Count) {
        Say "   Alles al binnen$(if ($skipped) { " ($skipped bewust overgeslagen)" })." Green
        return $true
    }

    $secs = [math]::Max(10, [math]::Ceiling($pending.Count / 34) * 220)
    Say "   $($pending.Count) nummer(s) zoeken op Soulseek..." Cyan
    if ($pending.Count -gt 30) { Say "   (Soulseek staat ~34 zoekopdrachten per 4 min toe: reken op ~$([math]::Ceiling($secs / 60)) min)" DarkGray }
    try {
        $allResults = Search-Tracks $pending $key
    } catch {
        Say "   Zoeken mislukt: $($_.Exception.Message)" Red
        return $false
    }

    # Eerst alles kiezen, dan alles downloaden: zo kun je daarna weglopen.
    $todo = New-Object System.Collections.ArrayList
    $auto = ($Mode -eq 'automatisch') -or $Proef
    for ($i = 0; $i -lt $pending.Count; $i++) {
        $t = $pending[$i]
        $groups = @(Group-Versions $allResults[$i] $t)
        Say ''
        Say ("   [{0}/{1}] {2} - {3}   (Spotify {4})" -f ($i + 1), $pending.Count, $t.Artist, $t.Title, (Format-Length $t.Length)) White
        if (-not $groups.Count) {
            $what = if (Is-Yes $cfg['tim-selector']) { 'niet in mp3 320 gevonden' } elseif (Is-Yes $cfg['alleen-flac']) { 'niet in FLAC gevonden' } else { 'niet gevonden' }
            Say "         $what, volgende keer opnieuw." Yellow
            continue
        }
        $shown = [math]::Min($groups.Count, 12)
        for ($g = 0; $g -lt $shown; $g++) {
            $v = $groups[$g]
            $mark = if ($g -eq 0) { '*' } else { ' ' }
            Say ("        {0}{1,2}. {2,-34} {3,5}  {4,3} bron(nen)  {5}" -f $mark, ($g + 1), $v.Display, (Format-Length $v.Length), $v.Sources, $v.Quality)
        }
        if ($groups.Count -gt $shown) { Say "            ... en nog $($groups.Count - $shown) zeldzamere versies" DarkGray }

        $picks = @(0)
        if ($Proef) { continue }
        if (-not $auto -and $groups.Count -gt 1) {
            while ($true) {
                $answer = (Read-Host '        Keuze [Enter = *, nummer(s) bijv. 1,3, s = overslaan, l = later, a = rest automatisch]').Trim().ToLower()
                if ($answer -eq '') { break }
                if ($answer -eq 'a') { $auto = $true; break }
                if ($answer -eq 's') { $picks = @(-1); break }
                if ($answer -eq 'l') { $picks = @(-2); break }
                # een of meer nummers, gescheiden door komma's en/of spaties
                if ($answer -match '^\d+([\s,]+\d+)*$') {
                    $nums = @($answer -split '[\s,]+' | ForEach-Object { [int]$_ } | Select-Object -Unique)
                    if (-not @($nums | Where-Object { $_ -lt 1 -or $_ -gt $shown }).Count) {
                        $picks = @($nums | ForEach-Object { $_ - 1 }); break
                    }
                }
                Say '        Snap ik niet, probeer opnieuw.' Yellow
            }
        }
        if ($picks[0] -eq -1) {
            $choices[$t.Uri] = @{ status = 'overgeslagen'; titel = "$($t.Artist) - $($t.Title)" }
            Save-Choices $choices $choicesPath
            Say '         overgeslagen (wordt niet meer gevraagd)' DarkGray
            continue
        }
        if ($picks[0] -eq -2) { Say '         volgende keer opnieuw' DarkGray; continue }
        Say "         -> $(($picks | ForEach-Object { $groups[$_].Display }) -join ' + ')" Green
        foreach ($p in $picks) { [void]$todo.Add(@{ Track = $t; Group = $groups[$p] }) }
    }

    if ($Proef) { Say ''; Say "   (proef) niets gedownload; * = wat hij zou kiezen" DarkGray; return $true }
    if (-not $todo.Count) { return $true }

    Say ''
    Say "   $($todo.Count) bestand(en) downloaden naar $outDir" Cyan
    $picks = @($todo | ForEach-Object {
        $suffix = if ($_.Group.Label) { " ($($_.Group.Display))" } else { '' }
        @{ Track = $_.Track; Group = $_.Group; Candidates = $_.Group.Candidates; File = $null
           Title = "{0} - {1}{2}" -f $_.Track.Artist, (Split-Title $_.Track.Title).Base, $suffix }
    })
    $tmp = Join-Path $StatusDir 'download-tmp'
    Download-Picks $picks $tmp
    $ok = Save-Picks $picks $outDir $choicesPath
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Say "   $ok van $($picks.Count) gelukt." $(if ($ok -eq $picks.Count) { 'Green' } else { 'Yellow' })
    return $true
}

# Oude route: sockseek doet alles zelf en pakt de versie die qua lengte
# overeenkomt met Spotify.
function Sync-Automatic($tracks, $key, $outDir, $src) {
    if ($Proef) { Say "   (proef) zou downloaden naar $outDir"; return $true }
    if ($HasSpotifyApp -and (Get-SpotifyRef $src)) {
        $ssInput = $src; $inputType = 'spotify'
    } else {
        $ssInput = Join-Path $StatusDir "$key.csv"; $inputType = 'csv'
        Write-TrackCsv $tracks $ssInput
    }
    $indexPath = Join-Path $StatusDir "$key.index.csv"
    & $Exe $ssInput --input-type $inputType --config $ConfPath --output-dir $outDir `
        --index-path $indexPath --log-file $LogFile --listen-port (Get-FreePort)
    # 0 = alles gelukt, 1 = een deel niet gevonden (normaal), hoger = echte fout
    if ($LASTEXITCODE -gt 1) {
        Say "   sockseek stopte met foutcode $LASTEXITCODE (zie status\laatste-run.log)." Red
        return $false
    }
    # Statussen in de index: 1 = gedownload, 2 = mislukt, 3 = stond er al
    if (Test-Path $indexPath) {
        $rows = @(Import-Csv $indexPath -Encoding UTF8)
        $ok   = @($rows | Where-Object { $_.state -in '1', '3' }).Count
        $miss = @($rows | Where-Object { $_.state -eq '2' })
        Say "   $ok van $($rows.Count) binnen -> $outDir" Green
        if ($miss.Count) {
            $what = if (Is-Yes $cfg['tim-selector']) { 'niet (in mp3 320) gevonden' } elseif (Is-Yes $cfg['alleen-flac']) { 'niet (in FLAC) gevonden' } else { 'niet gevonden' }
            Say "   $($miss.Count) $what, volgende keer opnieuw geprobeerd:" Yellow
            $miss | Select-Object -First 10 | ForEach-Object { Say "      $($_.artist) - $($_.title)" }
            if ($miss.Count -gt 10) { Say "      ... en nog $($miss.Count - 10)" }
        }
    }
    return $true
}

# --- playlists ophalen ----------------------------------------------------

# Geeft @{ Name; Key; Tracks; Cover; Spotify } voor een regel uit [playlists].
function Resolve-Playlist($pl) {
    $src = $pl.Source
    $ref = Get-SpotifyRef $src
    if ($ref) {
        try {
            $info = Get-SpotifyTracks $ref
        } catch {
            throw "Spotify-playlist niet te lezen ($($_.Exception.Message)). Is hij openbaar? Prive-playlists kan de tool niet zien."
        }
        return @{ Name = $(if ($pl.Name) { $pl.Name } else { $info.Name }); Key = $ref.Id
                  Tracks = $info.Tracks; Cover = $info.Cover; Spotify = $true; Full = $info.Full; Note = $info.Note }
    }
    $path = Expand-Home $src
    if (Test-Path -LiteralPath $path) {
        $name = if ($pl.Name) { $pl.Name } else { [IO.Path]::GetFileNameWithoutExtension($path) }
        return @{ Name = $name; Key = 'csv-' + (Safe-FileName $name); Tracks = @(Get-CsvTracks $path)
                  Cover = $null; Spotify = $false }
    }
    throw "Snap deze regel niet: $src. Verwacht een Spotify-link (playlist of album) of het pad naar een CSV."
}

# --- consoleversie ----------------------------------------------------------

function Run-Console {
    $err = Load-Config
    if ($err) {
        Say $err Red
        Say 'instellingen.ini gaat open. Sla op, sluit het, en start opnieuw.' Yellow
        Open-Editor $Ini
        return 1
    }
    if ($cfg['playlists'].Count -eq 0) {
        Say 'Er staan nog geen playlists onder [playlists] in instellingen.ini.' Red
        Open-Editor $Ini
        return 1
    }
    if (-not (Test-Path $Exe)) { Install-Sockseek }
    if (-not (Test-Soulseek)) { Say $NoSoulseekMsg Red; return 1 }
    New-Item -ItemType Directory -Force $MusicDir | Out-Null

    $failed = 0
    foreach ($pl in $cfg['playlists']) {
        Say ''
        try {
            $info = Resolve-Playlist $pl
        } catch {
            Say $_.Exception.Message Red
            $failed++; continue
        }
        $tracks = $info.Tracks; $key = $info.Key; $name = $info.Name

        Say "== $name  ($($tracks.Count) nummers)" Cyan
        if ($info.Spotify -and -not $info.Full -and $tracks.Count -ge 100 -and -not ($Mode -eq 'uit' -and $HasSpotifyApp)) {
            Say '   Let op: zonder Spotify-koppeling ziet de tool maar 100 nummers. Zie README.md.' Yellow
            if ($info.Note) { Say "   $($info.Note)" Yellow }
        }

        # Nieuw sinds vorige keer? Alleen ter info.
        $seenPath = Join-Path $StatusDir "$key.gezien.txt"
        if (Test-Path $seenPath) {
            $seen = @{}
            [IO.File]::ReadAllLines($seenPath, $Utf8) | ForEach-Object { $seen[$_] = $true }
            $new = @($tracks | Where-Object { -not $seen[$_.Uri] })
            if ($new.Count) {
                Say "   $($new.Count) nieuw sinds de vorige keer." Green
            } else {
                Say '   Geen nieuwe nummers op de playlist.'
            }
        } else {
            Say '   Eerste keer voor deze playlist.'
        }

        $outDir = Join-Path $MusicDir (Safe-FileName $name)
        $done = if ($Mode -eq 'uit') { Sync-Automatic $tracks $key $outDir $pl.Source } else { Sync-WithChoice $tracks $key $outDir }
        if (-not $done) { $failed++; continue }
        if (-not $Proef) { [void](Write-PlaylistM3u $info $outDir) }
        if (-not $Proef) {
            [IO.File]::WriteAllLines($seenPath, [string[]]@($tracks | ForEach-Object { $_.Uri }), $Utf8)
        }
    }

    Say ''
    if ($failed) { Say "$failed playlist(s) gingen mis, zie hierboven." Yellow; return 1 }
    Say 'Alles bijgewerkt.' Green
    return 0
}

# --- zoekresultaten bewaren (voor de webinterface) ------------------------

function Read-Results($key) {
    $path = Join-Path $StatusDir "$key.resultaten.json"
    $h = @{}
    if (Test-Path $path) {
        $obj = [IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    }
    return $h
}

function Save-Results($h, $key) {
    $path = Join-Path $StatusDir "$key.resultaten.json"
    [IO.File]::WriteAllText($path, ($h | ConvertTo-Json -Depth 8 -Compress), $Utf8)
}

# --- achtergrondtaak (gestart door de webinterface) -------------------------
#
# Het taakbestand is JSON: { type: zoeken|downloaden, index, uris: [...],
# picks: [{ uri, label }] }. Voortgang gaat naar status\taak.json.

function Run-Task($taskFile) {
    $task = [IO.File]::ReadAllText($taskFile, $Utf8) | ConvertFrom-Json
    $script:TaskState = @{
        type = $task.type; index = $task.index; name = ''; state = 'bezig'; phase = 'starten'
        started = (Get-Date).ToString('o'); log = @(); done = 0; total = 0; current = ''; message = ''
        pid = $PID
    }
    Update-Task @{} -Force
    $tmp = Join-Path $StatusDir 'download-tmp'
    try {
        # analyse heeft geen Soulseek nodig
        if ($task.type -eq 'installeren') { Run-AnalyseInstall; return }
        if ($task.type -eq 'analyseren') { Run-Analyse $task; return }
        $err = Load-Config
        if ($err) { throw $err }
        if (-not (Test-Path $Exe)) {
            Add-TaskLog 'sockseek ophalen bij GitHub (eenmalig, ~115 MB)...'
            Install-Sockseek
        }
        Update-Task @{ phase = 'verbinden' } -Force
        Add-TaskLog 'Verbinden met de Soulseek-server...'
        if (-not (Test-Soulseek)) { Add-TaskLog 'Soulseek-server niet bereikbaar'; throw $NoSoulseekMsg }
        Add-TaskLog 'Soulseek-server bereikbaar'
        Add-TaskLog 'Playlist ophalen bij Spotify'

        $pl = $cfg['playlists'][[int]$task.index]
        $info = Resolve-Playlist $pl
        Update-Task @{ name = $info.Name } -Force
        $byUri = @{}
        foreach ($t in $info.Tracks) { $byUri[$t.Uri] = $t }

        if ($task.type -eq 'zoeken') {
            $tracks = @($task.uris | ForEach-Object { $byUri[$_] } | Where-Object { $_ })
            if (-not $tracks.Count) { throw 'Geen nummers om te zoeken.' }
            Add-TaskLog "$($tracks.Count) nummer(s) zoeken op Soulseek"
            $all = Search-Tracks $tracks $info.Key
            $results = Read-Results $info.Key
            $found = 0
            for ($i = 0; $i -lt $tracks.Count; $i++) {
                # gaat er bij een nummer iets mis, dan niet de hele zoekronde weggooien
                try {
                    $groups = @(Group-Versions $all[$i] $tracks[$i] | Select-Object -First 12 | ForEach-Object {
                        @{ label = $_.Label; display = $_.Display; length = $_.Length; sources = $_.Sources
                           free = $_.Free; quality = $_.Quality; score = $_.Score; candidates = @($_.Candidates)
                           example = Get-RemoteName $_.Candidates[0].f }
                    })
                } catch {
                    $groups = @()
                    Add-TaskLog "Overgeslagen: $($tracks[$i].Artist) - $($tracks[$i].Title): $($_.Exception.Message)"
                }
                if ($groups.Count) { $found++ }
                $results[$tracks[$i].Uri] = @{ at = (Get-Date).ToString('o'); groups = $groups }
            }
            Save-Results $results $info.Key
            $msg = "$found van $($tracks.Count) gevonden. Kies nu de versies."
            if ($found -lt $tracks.Count) { $msg = "$found van $($tracks.Count) gevonden; de rest staat onder Niet gevonden." }
            Update-Task @{ state = 'klaar'; message = $msg } -Force
        } else {
            $results = Read-Results $info.Key
            $picks = @(foreach ($pk in $task.picks) {
                $t = $byUri[$pk.uri]
                $r = $results[$pk.uri]
                if (-not $t -or -not $r) { continue }
                $g = @($r.groups) | Where-Object { $_.label -eq $pk.label } | Select-Object -First 1
                if (-not $g) { continue }
                $suffix = if ($g.label) { " ($($g.display))" } else { '' }
                @{ Track = $t; Group = $g; Candidates = @($g.candidates); File = $null
                   Title = "{0} - {1}{2}" -f $t.Artist, (Split-Title $t.Title).Base, $suffix }
            })
            if (-not $picks.Count) { throw 'Niets om te downloaden; zoek eerst opnieuw.' }
            $outDir = Join-Path $MusicDir (Safe-FileName $info.Name)
            Add-TaskLog "$($picks.Count) bestand(en) downloaden naar $outDir"
            Download-Picks $picks $tmp
            $ok = Save-Picks $picks $outDir (Join-Path $StatusDir "$($info.Key).keuzes.json")
            [void](Write-PlaylistM3u $info $outDir)
            $msg = "$ok van $($picks.Count) bestand(en) binnen."
            if ($ok -lt $picks.Count) { $msg += ' De rest had geen bereikbare bron; probeer het later nog eens.' }
            Update-Task @{ state = 'klaar'; message = $msg; done = $ok } -Force
        }
    } catch {
        Update-Task @{ state = 'fout'; message = $_.Exception.Message } -Force
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- export naar rekordbox ------------------------------------------------
#
# Traktor bewaart zijn analyse (BPM, key, beatgrid, cues) in collection.nml.
# Daarvan maken we een rekordbox.xml, het officiele importformaat van rekordbox
# (Voorkeuren > Geavanceerd > Database > rekordbox xml). collection.nml wordt
# alleen gelezen, nooit aangepast.

$Inv = [Globalization.CultureInfo]::InvariantCulture

# Nieuwste collection.nml van Traktor, of $null.
function Find-TraktorCollection {
    $docs = @([Environment]::GetFolderPath('MyDocuments'), (Join-Path $HOME 'Documents')) | Where-Object { $_ } | Select-Object -Unique
    $found = foreach ($d in $docs) {
        $ni = Join-Path $d 'Native Instruments'
        if (Test-Path -LiteralPath $ni) {
            Get-ChildItem -LiteralPath $ni -Directory -Filter 'Traktor*' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'collection.nml') -ErrorAction SilentlyContinue }
        }
    }
    $nml = $found | Where-Object { $_ } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($nml) { return $nml.FullName }
    return $null
}

# Traktor MUSICAL_KEY 0-23 -> toonsoort zoals rekordbox hem schrijft
$RbKeys = 'C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B',
          'Cm', 'Dbm', 'Dm', 'Ebm', 'Em', 'Fm', 'F#m', 'Gm', 'Abm', 'Am', 'Bbm', 'Bm'
# Traktor-trackkleur 1-7 -> rekordbox-kleur
$RbColours = @{ '1' = '0xFF0000'; '2' = '0xFFA500'; '3' = '0xFFFF00'; '4' = '0x00FF00'; '5' = '0x0000FF'; '6' = '0x660099'; '7' = '0xFF007F' }
# Traktor-cuetype -> kleur van de hotcue (R, G, B), zoals Traktor ze toont
$RbCueColours = @{ '0' = 0, 120, 255; '1' = 255, 140, 0; '2' = 255, 140, 0; '3' = 255, 210, 0; '5' = 40, 226, 20 }

function Num($s) { return [double]::Parse("$s", $Inv) }
function Fmt($d, $f = '0.000') { return ([double]$d).ToString($f, $Inv) }

# Traktor schrijft een pad als schijf + "/:Users/:jij/:Music/:" + bestand.
#   Windows: "C:" + ... -> "C:/Users/jij/Music/x.flac"
#   Mac:     "Macintosh HD" + ... -> "/Users/jij/Music/x.flac" (de opstartschijf);
#            een andere schijf staat onder /Volumes/<naam>
function Join-NmlPath($volume, $rest) {
    $rest = $rest -replace '/:', '/'
    if ($OnWin) { return $volume + $rest }
    $other = "/Volumes/$volume$rest"
    if ($volume -and (Test-Path -LiteralPath $other)) { return $other }
    return $rest
}

function Get-NmlPath($loc) {
    return Join-NmlPath $loc.VOLUME ($loc.DIR + $loc.FILE)
}

# PRIMARYKEY van een playlist-regel: "C:/:Users/:jij/:x.flac" of "Macintosh HD/:Users/:jij/:x.flac"
function Get-NmlKeyPath($key) {
    $i = $key.IndexOf('/:')
    if ($i -lt 0) { return $key }
    return Join-NmlPath $key.Substring(0, $i) $key.Substring($i)
}

function Get-FileUrl($path) {
    $parts = ($path -replace '\\', '/') -split '/'
    if (-not $OnWin) {        # "/Users/jij/x.flac" -> file://localhost/Users/jij/x.flac
        return 'file://localhost' + ((@($parts) | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
    }
    $enc = @($parts[0]) + @($parts | Select-Object -Skip 1 | ForEach-Object { [Uri]::EscapeDataString($_) })
    return 'file://localhost/' + ($enc -join '/')
}

function Get-Kind($path) {
    switch -Regex ([IO.Path]::GetExtension($path).ToLower()) {
        '^\.flac$' { 'FLAC File' } '^\.mp3$' { 'MP3 File' } '^\.wav$' { 'WAV File' }
        '^\.aiff?$' { 'AIFF File' } '^\.m4a$' { 'M4A File' } default { 'Audio File' }
    }
}

function Export-Rekordbox {
    [void](Load-Config)
    $nmlPath = Find-TraktorCollection
    $nml = New-Object Xml.XmlDocument
    # Zonder Traktor: een lege collectie, dan gaan alleen de PlaylistFlac-playlists
    # mee en analyseert rekordbox ze zelf.
    if ($nmlPath) { $nml.Load($nmlPath) } else { $nml.LoadXml('<NML><COLLECTION/><PLAYLISTS/></NML>') }

    $tracks = New-Object Collections.ArrayList
    $byPath = @{}          # pad (kleine letters, /) -> TrackID
    $stats = @{ tracks = 0; grids = 0; keys = 0; hotcues = 0; memory = 0; loops = 0; ontbreekt = 0 }

    foreach ($e in $nml.NML.COLLECTION.ENTRY) {
        $loc = $e.LOCATION
        if (-not $loc -or -not $loc.FILE) { continue }
        $path = Get-NmlPath $loc
        if (-not (Test-Path -LiteralPath $path)) { $stats.ontbreekt++; continue }
        $id = $tracks.Count + 1
        $info = $e.INFO
        $t = [ordered]@{
            TrackID = $id; Name = $e.TITLE; Artist = $e.ARTIST; Album = $e.ALBUM.TITLE
            Genre = $info.GENRE; Kind = (Get-Kind $path); Size = (Get-Item -LiteralPath $path).Length
            TotalTime = [int]$info.PLAYTIME; BitRate = $(if ($info.BITRATE) { [int]([int]$info.BITRATE / 1000) } else { 0 })
            Comments = $info.COMMENT; PlayCount = $(if ($info.PLAYCOUNT) { $info.PLAYCOUNT } else { 0 })
            Rating = $(if ($info.RANKING) { $info.RANKING } else { 0 }); Label = $info.LABEL; Remixer = $info.REMIXER
            Location = (Get-FileUrl $path)
        }
        if ($info.IMPORT_DATE) {
            $d = $info.IMPORT_DATE -split '/'
            if ($d.Count -eq 3) { $t.DateAdded = '{0}-{1:00}-{2:00}' -f $d[0], [int]$d[1], [int]$d[2] }
        }
        if ($e.TEMPO -and $e.TEMPO.BPM) { $t.AverageBpm = Fmt (Num $e.TEMPO.BPM) '0.00' }
        if ($e.MUSICAL_KEY -and "$($e.MUSICAL_KEY.VALUE)" -match '^\d+$' -and [int]$e.MUSICAL_KEY.VALUE -lt 24) {
            $t.Tonality = $RbKeys[[int]$e.MUSICAL_KEY.VALUE]; $stats.keys++
        }
        if ($info.COLOR -and $RbColours[$info.COLOR]) { $t.Colour = $RbColours[$info.COLOR] }

        $tempos = New-Object Collections.ArrayList
        $marks = New-Object Collections.ArrayList
        $grids = @($e.CUE_V2 | Where-Object { $_.TYPE -eq '4' } | Sort-Object { Num $_.START })
        for ($g = 0; $g -lt $grids.Count; $g++) {
            $bpm = if ($grids[$g].GRID.BPM) { Num $grids[$g].GRID.BPM } elseif ($e.TEMPO.BPM) { Num $e.TEMPO.BPM } else { 0 }
            if ($bpm -le 0) { continue }
            # rekenen met de BPM zoals rekordbox hem krijgt (2 decimalen); anders telt
            # het afrondingsverschil per tel op en valt het grid naast de Traktor-marker
            $bpm = [math]::Round($bpm, 2)
            $start = (Num $grids[$g].START) / 1000
            $beat = 1
            if ($g -eq 0) {
                # rekordbox wil een grid vanaf het begin: terugrekenen naar de eerste tel
                # na 0 s, en bijhouden welke tel in de maat dat dan is
                $len = 60 / $bpm
                $k = [math]::Floor($start / $len)
                $start = $start - $k * $len
                $beat = ((4 - ($k % 4)) % 4) + 1
            }
            [void]$tempos.Add([ordered]@{ Inizio = (Fmt $start); Bpm = (Fmt $bpm '0.00'); Metro = '4/4'; Battito = $beat })
        }
        if ($tempos.Count) { $stats.grids++ }

        foreach ($c in $e.CUE_V2) {
            if ($c.TYPE -eq '4') { continue }
            $num = [int]$c.HOTCUE
            $isLoop = $c.TYPE -eq '5' -and (Num $c.LEN) -gt 0
            $m = [ordered]@{
                Name = $(if ($c.NAME -and $c.NAME -ne 'n.n.') { $c.NAME } else { '' })
                Type = $(if ($isLoop) { 4 } else { 0 })
                Start = (Fmt ((Num $c.START) / 1000))
            }
            if ($isLoop) { $m.End = Fmt (((Num $c.START) + (Num $c.LEN)) / 1000); $stats.loops++ }
            $m.Num = $(if ($num -ge 0 -and $num -le 7) { $num } else { -1 })
            if ($m.Num -ge 0) {
                $rgb = $RbCueColours[$c.TYPE]
                if ($rgb) { $m.Red = $rgb[0]; $m.Green = $rgb[1]; $m.Blue = $rgb[2] }
                $stats.hotcues++
            } else { $stats.memory++ }
            [void]$marks.Add($m)
        }

        [void]$tracks.Add(@{ Attr = $t; Tempos = $tempos; Marks = $marks })
        $byPath[$path.ToLower()] = $id
    }

    # Traktor-playlists, met de mappen zoals in Traktor
    $plNodes = New-Object Collections.ArrayList
    function Convert-NmlNode($node) {
        $out = foreach ($n in @($node.NODE)) {
            if (-not $n) { continue }
            if ($n.TYPE -eq 'FOLDER') {
                $kids = @(Convert-NmlNode $n.SUBNODES)
                if ($kids.Count) { @{ Name = $n.NAME; Folder = $true; Kids = $kids } }
            } elseif ($n.TYPE -eq 'PLAYLIST') {
                $ids = @($n.PLAYLIST.ENTRY | ForEach-Object {
                    $k = $_.PRIMARYKEY.KEY
                    if ($k) { $byPath[(Get-NmlKeyPath $k).ToLower()] }
                } | Where-Object { $_ })
                if ($ids.Count) { @{ Name = $n.NAME; Folder = $false; Ids = $ids } }
            }
        }
        return @($out)
    }
    $traktorLists = @(Convert-NmlNode $nml.NML.PLAYLISTS.NODE.SUBNODES)
    if ($traktorLists.Count) { [void]$plNodes.Add(@{ Name = 'Traktor'; Folder = $true; Kids = $traktorLists }) }

    # PlaylistFlac-playlists: in de volgorde van de .m3u8 (Spotify-volgorde),
    # anders alles in de map op naam. Wat Traktor nog niet kent, gaat zonder
    # analyse mee; rekordbox analyseert het dan zelf.
    $ours = foreach ($pl in $cfg['playlists']) {
        $name = if ($pl.Name) { $pl.Name } elseif ($script:PlCache[$pl.Source]) { $script:PlCache[$pl.Source].Info.Name } else { $null }
        if (-not $name) { try { $name = (Resolve-Playlist $pl).Name } catch { continue } }
        $dir = Join-Path $MusicDir (Safe-FileName $name)
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $m3u = @(Read-M3u (Join-Path $dir ((Safe-FileName $name) + '.m3u8')))
        $files = if ($m3u.Count) { @($m3u | ForEach-Object { Get-Item -LiteralPath $_ }) } else {
            @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -match '^\.(flac|mp3|wav|aiff?|m4a)$' } | Sort-Object Name)
        }
        $ids = @($files | Where-Object { $_.Extension -match '^\.(flac|mp3|wav|aiff?|m4a)$' } | ForEach-Object {
            $p = $_.FullName -replace '\\', '/'
            $id = $byPath[$p.ToLower()]
            if (-not $id) {
                $id = $tracks.Count + 1
                $base = $_.BaseName
                $artist = ''; $title = $base
                if ($base -match '^(?<a>.+?) - (?<t>.+)$') { $artist = $Matches.a; $title = $Matches.t }
                [void]$tracks.Add(@{ Attr = [ordered]@{ TrackID = $id; Name = $title; Artist = $artist; Kind = (Get-Kind $p)
                    Size = $_.Length; Location = (Get-FileUrl $p) }; Tempos = @(); Marks = @() })
                $byPath[$p.ToLower()] = $id
            }
            $id
        })
        if ($ids.Count) { @{ Name = $name; Folder = $false; Ids = $ids } }
    }
    $ours = @($ours)
    if ($ours.Count) { [void]$plNodes.Add(@{ Name = 'PlaylistFlac'; Folder = $true; Kids = $ours }) }
    $stats.tracks = $tracks.Count

    # schrijven
    $out = Join-Path $DataDir 'rekordbox.xml'
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = $Utf8
    $w = [Xml.XmlWriter]::Create($out, $settings)
    try {
        $w.WriteStartDocument()
        $w.WriteStartElement('DJ_PLAYLISTS'); $w.WriteAttributeString('Version', '1.0.0')
        $w.WriteStartElement('PRODUCT')
        $w.WriteAttributeString('Name', 'rekordbox'); $w.WriteAttributeString('Version', '6.0.0'); $w.WriteAttributeString('Company', 'AlphaTheta')
        $w.WriteEndElement()
        $w.WriteStartElement('COLLECTION'); $w.WriteAttributeString('Entries', "$($tracks.Count)")
        foreach ($t in $tracks) {
            $w.WriteStartElement('TRACK')
            foreach ($k in $t.Attr.Keys) { if ($null -ne $t.Attr[$k] -and "$($t.Attr[$k])" -ne '') { $w.WriteAttributeString($k, "$($t.Attr[$k])") } }
            foreach ($tp in $t.Tempos) {
                $w.WriteStartElement('TEMPO'); foreach ($k in $tp.Keys) { $w.WriteAttributeString($k, "$($tp[$k])") }; $w.WriteEndElement()
            }
            foreach ($m in $t.Marks) {
                $w.WriteStartElement('POSITION_MARK'); foreach ($k in $m.Keys) { $w.WriteAttributeString($k, "$($m[$k])") }; $w.WriteEndElement()
            }
            $w.WriteEndElement()
        }
        $w.WriteEndElement()

        function Write-RbNode($w, $n) {
            $w.WriteStartElement('NODE')
            if ($n.Folder) {
                $w.WriteAttributeString('Type', '0'); $w.WriteAttributeString('Name', $n.Name); $w.WriteAttributeString('Count', "$(@($n.Kids).Count)")
                foreach ($kid in $n.Kids) { Write-RbNode $w $kid }
            } else {
                $w.WriteAttributeString('Name', $n.Name); $w.WriteAttributeString('Type', '1'); $w.WriteAttributeString('KeyType', '0')
                $w.WriteAttributeString('Entries', "$(@($n.Ids).Count)")
                foreach ($id in $n.Ids) { $w.WriteStartElement('TRACK'); $w.WriteAttributeString('Key', "$id"); $w.WriteEndElement() }
            }
            $w.WriteEndElement()
        }
        $w.WriteStartElement('PLAYLISTS')
        Write-RbNode $w @{ Name = 'ROOT'; Folder = $true; Kids = @($plNodes) }
        $w.WriteEndElement()
        $w.WriteEndElement()
        $w.WriteEndDocument()
    } finally {
        $w.Close()
    }
    $stats.bestand = $out
    $stats.bron = $nmlPath
    $stats.traktor = [bool]$nmlPath
    $stats.playlists = @($traktorLists).Count + @($ours).Count
    return $stats
}

# --- analyse (BPM, beatgrid, cues, key) --------------------------------------
#
# Optioneel. Eenmalig installeren zet Python-pakketten (PyTorch, librosa en
# Beat This!) in data\analyse\venv; dat is ruim 1 GB. Daarna schrijft
# app\analyse\analyse.py per playlist een .nml (Traktor) en een rekordbox.xml
# naar data\export. De muziekbestanden zelf worden alleen gelezen.

$BeatThisUrl = 'https://github.com/CPJKU/beat_this/archive/refs/tags/v1.1.0.zip'
$AnaDoen = 'grid', 'cues', 'key', 'keyschatting', 'energie'
$AnaFormaten = 'traktor', 'rekordbox'

# Python 3.10 of nieuwer: liefst een versie waarmee de analyse getest is (via de
# py-launcher), anders de nieuwste die er is, dan python op het PATH. Op een Mac
# python3.13 enz.; de python3 die macOS zelf meebrengt is 3.9 en valt dus af.
function Find-Python {
    $tries = if ($OnWin) { @(@('py', '-3.13'), @('py', '-3.12'), @('py', '-3.11'), @('py', '-3.10'), @('py', '-3'), @('python')) }
             else {
                 $dirs = '/Library/Frameworks/Python.framework/Versions/{0}/bin/python{0}', '/opt/homebrew/bin/python{0}', '/usr/local/bin/python{0}'
                 @(foreach ($v in '3.13', '3.12', '3.11', '3.10') { , @("python$v"); foreach ($d in $dirs) { , @($d -f $v) } }) + @(, @('python3'))
             }
    foreach ($c in $tries) {
        $exe = $c[0]; $pre = @($c | Select-Object -Skip 1)
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $out = @(& $exe @pre -c 'import sys; print(sys.executable); print(sys.version_info[0] * 100 + sys.version_info[1])' 2>$null)
        } catch { continue }
        if ($out.Count -ge 2 -and "$($out[1])" -match '^\d+$' -and [int]$out[1] -ge 310 -and (Test-Path -LiteralPath $out[0])) {
            return @{ Path = "$($out[0])"; Version = ('{0}.{1}' -f [math]::Floor([int]$out[1] / 100), ([int]$out[1] % 100)) }
        }
    }
    return $null
}

function Get-AnalyseState {
    # Python zoeken kost een fractie van een seconde; niet bij elke poll opnieuw
    if (-not $script:PyAt -or (-not $script:PyInfo -and ((Get-Date) - $script:PyAt).TotalSeconds -gt 15)) {
        $script:PyInfo = Find-Python; $script:PyAt = Get-Date
    }
    return [ordered]@{
        installed = [bool]((Test-Path $AnaReady) -and (Test-Path $AnaPy))
        python = $(if ($script:PyInfo) { $script:PyInfo.Version } else { $null })
        exportDir = $ExportDir
    }
}

function Last-Lines($text, [int]$n = 3) {
    return ((@("$text" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last $n) -join ' / ')
}

# Draait een programma en geeft elke regel van stdout aan $OnLine. stderr wordt
# apart (en zonder vast te lopen) bewaard voor een eventuele foutmelding.
function Invoke-Logged([string]$FilePath, [string[]]$ArgList, [scriptblock]$OnLine) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $psi.EnvironmentVariables['TORCH_HOME'] = (Join-Path $AnaDir 'torch')
    $p = [Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEndAsync()
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        if ($line.Trim()) { & $OnLine $line }
    }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Err = $err.Result }
}

function Run-AnalyseInstall {
    Update-Task @{ name = 'Analyse'; phase = 'installeren'; total = 4; done = 0 } -Force
    $py = Find-Python
    if (-not $py) {
        if ($OnWin) { throw 'Python niet gevonden. Installeer Python 3 van python.org (vink "Add python.exe to PATH" aan) en probeer het daarna opnieuw.' }
        throw 'Python niet gevonden. Installeer Python 3.13 van python.org (de macOS-installer) en probeer het daarna opnieuw.'
    }
    Add-TaskLog "Python $($py.Version) gevonden: $($py.Path)"
    New-Item -ItemType Directory -Force $AnaDir | Out-Null
    if (Test-Path $AnaReady) { Remove-Item $AnaReady -Force }
    $pipLog = { param($l) if ($l -match '^(Collecting|Successfully|ERROR)') { Add-TaskLog $l.Trim() } }
    if (-not (Test-Path $AnaPy)) {
        Add-TaskLog 'Eigen Python-omgeving maken in data\analyse'
        $r = Invoke-Logged $py.Path @('-m', 'venv', (Join-Path $AnaDir 'venv')) $pipLog
        if ($r.Code) { throw "Python-omgeving maken mislukte: $(Last-Lines $r.Err)" }
    }
    Update-Task @{ done = 1 } -Force
    $pip = @('-m', 'pip', 'install', '--disable-pip-version-check', '--progress-bar', 'off')
    Add-TaskLog 'PyTorch installeren (ongeveer 800 MB, dit duurt even)'
    # Windows: de versie zonder videokaart-ondersteuning (kleiner). Een Mac haalt
    # PyTorch gewoon van PyPI; die heeft geen aparte cpu-variant.
    $torch = @('torch', 'torchaudio') + $(if ($OnMac) { @() } else { @('--index-url', 'https://download.pytorch.org/whl/cpu') })
    $r = Invoke-Logged $AnaPy ($pip + $torch) $pipLog
    if ($r.Code) { throw "PyTorch installeren mislukte: $(Last-Lines $r.Err)" }
    Update-Task @{ done = 2 } -Force
    Add-TaskLog 'librosa, Beat This! en de rest installeren'
    $r = Invoke-Logged $AnaPy ($pip + @('librosa', 'soundfile', 'soxr', 'einops', 'rotary-embedding-torch', 'mutagen', 'certifi', $BeatThisUrl)) $pipLog
    if ($r.Code) { throw "Installeren mislukte: $(Last-Lines $r.Err)" }
    Update-Task @{ done = 3 } -Force
    Add-TaskLog 'Controleren en het Beat This!-model ophalen (80 MB)'
    $r = Invoke-Logged $AnaPy @('-I', $AnaScript, '--check') { param($l) try { Add-TaskLog ($l | ConvertFrom-Json).msg } catch { } }
    if ($r.Code) { throw "Controle mislukte: $(Last-Lines $r.Err)" }
    [IO.File]::WriteAllText($AnaReady, "PlaylistFlac $Version`r`n$((Get-Date).ToString('o'))`r`n", $Utf8)
    Update-Task @{ done = 4; state = 'klaar'; message = 'De analyse is geinstalleerd. Kies nu Analyseren & exporteren.' } -Force
}

# Muziekbestanden van een playlist: in de volgorde van de .m3u8 (Spotify-volgorde),
# anders alles in de map op naam.
function Get-PlaylistFiles($name) {
    $dir = Join-Path $MusicDir (Safe-FileName $name)
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $m3u = @(Read-M3u (Join-Path $dir ((Safe-FileName $name) + '.m3u8')) | Where-Object { Test-Path -LiteralPath $_ })
    $files = if ($m3u.Count) { $m3u } else {
        @(Get-ChildItem -LiteralPath $dir -File | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    return @($files | Where-Object { $_ -match '\.(flac|mp3|wav|aiff?|m4a)$' })
}

function Run-Analyse($task) {
    if (-not ((Test-Path $AnaReady) -and (Test-Path $AnaPy))) { throw 'De analyse is nog niet geinstalleerd.' }
    [void](Load-Config)
    $pl = $cfg['playlists'][[int]$task.index]
    $name = if ($pl.Name) { $pl.Name } elseif ($task.name -and $task.name -ne 'playlist') { $task.name } else { (Resolve-Playlist $pl).Name }
    Update-Task @{ name = $name; phase = 'analyseren' } -Force
    $files = @(Get-PlaylistFiles $name)
    if (-not $files.Count) { throw "Geen muziek gevonden in de map van $name. Download eerst wat nummers." }
    $doen = @($task.doen | Where-Object { $AnaDoen -contains $_ })
    $formaten = @($task.formaten | Where-Object { $AnaFormaten -contains $_ })
    if (-not $doen.Count -or -not $formaten.Count) { throw 'Kies wat je wilt analyseren en voor welke software.' }
    Update-Task @{ total = $files.Count; current = [IO.Path]::GetFileNameWithoutExtension($files[0]) } -Force
    Add-TaskLog ("{0} tracks analyseren: {1}" -f $files.Count, ($doen -join ', '))

    New-Item -ItemType Directory -Force $ExportDir | Out-Null
    $list = Join-Path $StatusDir 'analyse-lijst.txt'
    [IO.File]::WriteAllLines($list, [string[]]$files, $Utf8)
    $base = Join-Path $ExportDir (Safe-FileName $name)
    $out = @{}
    $argList = @('-I', $AnaScript, '--lijst', $list, '--naam', $name, '--doen', ($doen -join ','), '--rapport', "$base.analyse.json")
    if ($formaten -contains 'traktor') { $out.nml = "$base.nml"; $argList += @('--nml', $out.nml) }
    # Standaard alleen de nieuw geanalyseerde tracks naar Traktor: een import zet
    # anders de cues en het grid van de hele playlist terug, ook wat je zelf had verschoven.
    $nieuwNml = "$base (nieuw).nml"
    if ($out.nml -and -not $task.hele) { $argList += @('--nml-nieuw', $nieuwNml) }
    elseif (Test-Path -LiteralPath $nieuwNml) { Remove-Item -LiteralPath $nieuwNml -Force }
    if ($formaten -contains 'rekordbox') { $out.rekordbox = "$base (rekordbox).xml"; $argList += @('--rekordbox', $out.rekordbox) }
    # alleen lezen: bij het inladen zou Traktor anders de cover, het genre enz. kwijtraken
    $collectie = Find-TraktorCollection
    if ($collectie) { $argList += @('--collectie', $collectie) }
    $argList += @('--cache', (Join-Path $ExportDir 'analyse-cache.json'))
    if ($task.opnieuw) { $argList += '--opnieuw' }

    $st = @{ ok = 0; bewaard = 0; fout = 0; onzeker = 0; nalopen = 0; nieuw = 0 }
    $onLine = {
        param($l)
        try { $m = $l | ConvertFrom-Json } catch { return }
        if ($m.t -eq 'klaar') { $st.nieuw = [int]$m.nieuw; return }
        $next = if ([int]$m.i -lt $files.Count) { [IO.Path]::GetFileNameWithoutExtension($files[[int]$m.i]) } else { '' }
        if ($m.t -eq 'log') {
            Add-TaskLog $m.msg
        } elseif ($m.t -eq 'track' -and $m.bewaard) {
            $st.bewaard++
            Add-TaskLog ('Al geanalyseerd, overgeslagen: {0}' -f [IO.Path]::GetFileNameWithoutExtension($m.naam))
            Update-Task @{ done = [int]$m.i; current = $next } -Force
        } elseif ($m.t -eq 'track') {
            $st.ok++
            $bits = @()
            if ($m.bpm) { $bits += ('{0} BPM' -f ([double]$m.bpm).ToString('0.00', $Inv)) }
            if ($m.key) { $bits += "key $($m.key)" + $(if ($m.key_bron -eq 'geschat') { ' (geschat)' } else { ' (uit tags)' }) }
            if ($m.energy) { $bits += "energy $($m.energy) ($($m.kleur))" + $(if ($m.energy_bron -eq 'tags') { ' uit tags' } else { '' }) }
            if ($m.cues) { $bits += "$($m.cues) cues" }
            if ($m.onzeker) { $st.onzeker++ }
            if ($m.nalopen) { $bits += 'even nalopen'; $st.nalopen++ }
            if (-not $bits.Count) { $bits += 'niets gevonden' }
            Add-TaskLog ('Geanalyseerd: {0} - {1}' -f [IO.Path]::GetFileNameWithoutExtension($m.naam), ($bits -join ', '))
            Update-Task @{ done = [int]$m.i; current = $next } -Force
        } elseif ($m.t -eq 'fout') {
            $st.fout++
            Add-TaskLog "Mislukt: $($m.naam) - $($m.msg)"
            Update-Task @{ done = [int]$m.i; current = $next } -Force
        }
    }
    $r = Invoke-Logged $AnaPy $argList $onLine
    if ($r.Code) { throw "De analyse stopte met een fout: $(Last-Lines $r.Err)" }
    $msg = if ($st.bewaard) { "$($st.ok) tracks geanalyseerd, $($st.bewaard) overgeslagen omdat ze al klaar waren." } else { "$($st.ok) van $($files.Count) tracks geanalyseerd." }
    if ($st.fout) { $msg += " Bij $($st.fout) mislukt." }
    if ($st.nalopen) { $msg += " Bij $($st.nalopen) staat iets om na te lopen: zie Analyse bij de playlist." }
    $msg += ' Klaar in data\export: ' + ((@($out.Values) | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ' en ') + '.'
    if ($out.nml) {
        try {
            if ($task.hele) {
                $desk = Copy-NmlToDesktop $out.nml
                if ($desk) { $msg += " Voor Traktor staat de hele playlist op je bureaublad: $([IO.Path]::GetFileName($desk))." }
            } elseif ($st.nieuw) {
                $desk = Copy-NmlToDesktop $nieuwNml
                if ($desk) { $msg += " Voor Traktor staan de $($st.nieuw) nieuwe tracks op je bureaublad: $([IO.Path]::GetFileName($desk)). De rest blijft in Traktor zoals hij is." }
            } else {
                Remove-DesktopNml $out.nml     # anders importeer je per ongeluk de vorige keer opnieuw
                $msg += ' Geen nieuwe tracks, dus niets om in Traktor te importeren.'
            }
        } catch { Add-TaskLog "Kon de .nml niet op het bureaublad zetten: $($_.Exception.Message)" }
    }
    Update-Task @{ state = 'klaar'; message = $msg; done = $files.Count; current = ''; files = @($out.Values) } -Force
}

# Traktor opent zijn importvenster op het bureaublad; daar dus een kopie. Met een
# eigen achtervoegsel, zodat een eigen bestand met dezelfde naam nooit wordt overschreven.
# "<playlist> (nieuw).nml" komt er ook als "<playlist> (PlaylistFlac).nml" te staan.
function Get-DesktopNml($nml) {
    $desk = [Environment]::GetFolderPath('Desktop')
    if (-not $desk -or -not (Test-Path -LiteralPath $desk)) { return $null }
    $stem = [IO.Path]::GetFileNameWithoutExtension($nml) -replace ' \(nieuw\)$', ''
    return Join-Path $desk ($stem + ' (PlaylistFlac).nml')
}

function Copy-NmlToDesktop($nml) {
    $dest = Get-DesktopNml $nml
    if (-not $dest) { return $null }
    Copy-Item -LiteralPath $nml -Destination $dest -Force
    return $dest
}

function Remove-DesktopNml($nml) {
    $dest = Get-DesktopNml $nml
    if ($dest -and (Test-Path -LiteralPath $dest)) { Remove-Item -LiteralPath $dest -Force }
}

# --- bijwerken vanaf GitHub -------------------------------------------------

# Vergelijkt versies als 1.3.4-beta: <0 als $a ouder is dan $b, 0 als gelijk, >0 als nieuwer.
function Compare-AppVersion([string]$a, [string]$b) {
    $parse = {
        param($v)
        if ($v -notmatch '^v?(\d+(?:\.\d+)+)(-.+)?$') { throw "Onbekend versienummer: $v" }
        return @{ Nr = [version]$Matches[1]; Extra = "$($Matches[2])" }
    }
    $x = & $parse $a; $y = & $parse $b
    if ($x.Nr -ne $y.Nr) { return $x.Nr.CompareTo($y.Nr) }
    if ($x.Extra -eq $y.Extra) { return 0 }
    if (-not $x.Extra) { return 1 }       # 1.4.0 is nieuwer dan 1.4.0-beta
    if (-not $y.Extra) { return -1 }
    return [string]::CompareOrdinal($x.Extra, $y.Extra)
}

# De nieuwste uitgave op GitHub, ook als die beta is (/releases/latest slaat die over).
function Get-LatestRelease {
    $list = Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 "https://api.github.com/repos/$UpdateRepo/releases?per_page=20"
    $best = $null
    foreach ($r in $list) {
        if ($r.draft -or $r.tag_name -notmatch '^v?\d+(\.\d+)+(-.+)?$') { continue }
        $asset = @($r.assets | Where-Object { $_.name -match '^PlaylistFlac-.+\.zip$' }) | Select-Object -First 1
        if (-not $asset) { continue }
        $v = $r.tag_name -replace '^v', ''
        if (-not $best -or (Compare-AppVersion $v $best.Version) -gt 0) { $best = @{ Version = $v; Url = $asset.browser_download_url } }
    }
    return $best
}

function Get-UpdateInfo {
    $latest = Get-LatestRelease
    if (-not $latest) { return @{ current = $Version; latest = $null; newer = $false } }
    return @{ current = $Version; latest = $latest.Version; newer = ((Compare-AppVersion $latest.Version $Version) -gt 0) }
}

# Zet een uitgepakte versie over de huidige heen. data\ en app\bin zitten niet in de
# zip en blijven dus staan. Lukt het kopieren niet, dan gaat alles terug.
function Install-UpdateFiles($new, $work) {
    $rels = @(Get-ChildItem -LiteralPath $new -Recurse -File | ForEach-Object { $_.FullName.Substring($new.TrimEnd('\', '/').Length + 1) })
    foreach ($rel in $rels) {
        if ($rel -match '^(data|app[\\/]bin)([\\/]|$)') { throw "De update bevat een bestand dat er niet in hoort: $rel" }
    }
    $backup = Join-Path $work 'oud'
    $added = New-Object Collections.ArrayList
    foreach ($rel in $rels) {
        $cur = Join-Path $Root $rel
        if (Test-Path -LiteralPath $cur) {
            $bak = Join-Path $backup $rel
            New-Item -ItemType Directory -Force (Split-Path $bak) | Out-Null
            Copy-Item -LiteralPath $cur -Destination $bak -Force
        } else { [void]$added.Add($cur) }
    }
    try {
        foreach ($rel in $rels) {
            $dest = Join-Path $Root $rel
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            Copy-Item -LiteralPath (Join-Path $new $rel) -Destination $dest -Force
        }
    } catch {
        foreach ($rel in $rels) {
            $bak = Join-Path $backup $rel
            if (Test-Path -LiteralPath $bak) { Copy-Item -LiteralPath $bak -Destination (Join-Path $Root $rel) -Force }
        }
        foreach ($f in $added) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        throw "Bijwerken mislukt, de oude versie is teruggezet: $($_.Exception.Message)"
    }
}

function Install-Update {
    if (Task-Running) { throw 'Er loopt nog een taak. Bijwerken kan zodra die klaar is.' }
    $latest = Get-LatestRelease
    if (-not $latest -or (Compare-AppVersion $latest.Version $Version) -le 0) { throw 'Je hebt de nieuwste versie al.' }
    $work = Join-Path $StatusDir 'update'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $zip = Join-Path $work 'update.zip'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 $latest.Url -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'nieuw') -Force
    $new = Join-Path (Join-Path $work 'nieuw') 'PlaylistFlac'
    # eerst controleren of dit echt een werkende versie is; pas dan iets vervangen
    $script = Join-Path (Join-Path $new 'app') 'PlaylistFlac.ps1'
    foreach ($need in (Join-Path $new 'index.html'), $script, (Join-Path (Join-Path (Join-Path $new 'app') 'analyse') 'analyse.py')) {
        if (-not (Test-Path -LiteralPath $need)) { throw 'De download is niet compleet. Er is niets veranderd.' }
    }
    if (-not (Select-String -LiteralPath $script -SimpleMatch "'$($latest.Version)'" -Quiet)) { throw 'De download hoort niet bij deze versie. Er is niets veranderd.' }
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs)
    if ($errs) { throw 'De download bevat een fout. Er is niets veranderd.' }
    Install-UpdateFiles $new $work
    if (-not $OnWin) { & chmod +x (Join-Path $AppDir 'Start.command') }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    return $latest.Version
}

# --- webinterface -----------------------------------------------------------

$script:Worker = $null
$script:PlCache = @{}

function Read-TaskStatus {
    if (-not (Test-Path $TaskStatusPath)) { return $null }
    try { $t = [IO.File]::ReadAllText($TaskStatusPath, $Utf8) | ConvertFrom-Json } catch { return $null }
    $alive = $script:Worker -and -not $script:Worker.HasExited
    if ($t.state -eq 'bezig' -and -not $alive) {
        $t.state = 'fout'
        $t.message = 'De taak stopte onverwacht. Kijk in status\laatste-run.log.'
    }
    return $t
}

function Task-Running { return [bool]($script:Worker -and -not $script:Worker.HasExited) }

# --- wachtrij ---
# Zoeken en downloaden voor verschillende playlists gaan achter elkaar: er draait
# er maar een tegelijk (twee keer inloggen met hetzelfde Soulseek-account gooit
# elkaar eruit). Een opdracht onthoudt de link van zijn playlist, niet de plek
# in de lijst, zodat verwijderen of toevoegen van playlists hem niet in de war brengt.

$script:Queue = New-Object Collections.ArrayList
$script:CurrentTask = $null
$script:QueueId = 0

function Add-ToQueue($task) {
    [void](Load-Config)
    if ($task.type -eq 'installeren') {
        # hoort bij geen playlist
        $script:QueueId++
        $task.id = $script:QueueId; $task.src = ''; $task.name = 'Analyse'; $task.count = 1
        [void]$script:Queue.Add($task)
        Pump-Queue
        return
    }
    $pl = $cfg['playlists'][[int]$task.index]
    if (-not $pl) { throw 'Die playlist bestaat niet (meer).' }
    $c = $script:PlCache[$pl.Source]
    $script:QueueId++
    $task.id = $script:QueueId
    $task.src = $pl.Source
    $task.name = if ($pl.Name) { $pl.Name } elseif ($c) { $c.Info.Name } else { 'playlist' }
    $task.count = if ($task.type -eq 'downloaden') { @($task.picks).Count } elseif ($task.type -eq 'analyseren') { 0 } else { @($task.uris).Count }
    [void]$script:Queue.Add($task)
    Pump-Queue
}

# Start de volgende opdracht als er niets draait.
function Pump-Queue {
    while (-not (Task-Running) -and $script:Queue.Count) {
        $next = $script:Queue[0]
        $script:Queue.RemoveAt(0)
        [void](Load-Config)
        if ($next.type -ne 'installeren') {
            $idx = -1
            for ($i = 0; $i -lt $cfg['playlists'].Count; $i++) { if ($cfg['playlists'][$i].Source -eq $next.src) { $idx = $i; break } }
            if ($idx -lt 0) { continue }          # playlist intussen verwijderd
            $next.index = $idx
        }
        $script:CurrentTask = $next
        Start-Task $next
    }
}

# uri's van nummers die in de wachtrij staan of nu bezig zijn, voor deze playlist
function Get-QueuedUris($src) {
    $h = @{}
    $items = @($script:Queue) + $(if ((Task-Running) -and $script:CurrentTask) { @($script:CurrentTask) } else { @() })
    foreach ($q in $items) {
        if ($q.src -ne $src) { continue }
        if ($q.type -eq 'downloaden') { foreach ($p in $q.picks) { $h[$p.uri] = 'downloaden' } }
        else { foreach ($u in $q.uris) { if (-not $h[$u]) { $h[$u] = 'zoeken' } } }
    }
    return $h
}

function Start-Task($task) {
    if (Task-Running) { throw 'Er loopt al een taak.' }
    $file = Join-Path $StatusDir 'taak-opdracht.json'
    [IO.File]::WriteAllText($file, ($task | ConvertTo-Json -Depth 6), $Utf8)
    if (Test-Path $TaskStatusPath) { Remove-Item $TaskStatusPath -Force }
    $script:Worker = Start-Self ('-Taak ' + (Quote-Arg $file))
}

function Stop-Task {
    if (-not (Task-Running)) { return }
    # ook de sockseek of Python die de taak gestart heeft
    if ($OnWin) { & taskkill.exe /PID $script:Worker.Id /T /F | Out-Null }
    else { try { $script:Worker.Kill($true) } catch { } }
    $script:Worker.WaitForExit(5000) | Out-Null
    $t = Read-TaskStatus
    $state = @{ state = 'gestopt'; message = 'Gestopt.'; type = $(if ($t) { $t.type } else { '' }); index = $(if ($t) { $t.index } else { -1 }) }
    [IO.File]::WriteAllText($TaskStatusPath, ($state | ConvertTo-Json -Compress), $Utf8)
}

function Get-PlaylistInfo([int]$i, [switch]$Refresh) {
    $pl = $cfg['playlists'][$i]
    if (-not $pl) { throw 'Die playlist bestaat niet (meer).' }
    $c = $script:PlCache[$pl.Source]
    if ($Refresh -or -not $c -or ((Get-Date) - $c.At).TotalMinutes -gt 10) {
        $c = @{ At = (Get-Date); Info = (Resolve-Playlist $pl) }
        $script:PlCache[$pl.Source] = $c
    }
    $c.Info.Name = if ($pl.Name) { $pl.Name } else { $c.Info.Name }
    return $c.Info
}

# Alles wat de pagina over een playlist moet weten, per nummer met status.
# Het rapport van de laatste analyse van deze playlist (data\export\<naam>.analyse.json), of $null.
function Read-AnalyseRapport($name) {
    $path = Join-Path $ExportDir ((Safe-FileName $name) + '.analyse.json')
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return [IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json } catch { return $null }
}

function Get-PlaylistView([int]$i, [switch]$Refresh) {
    $info = Get-PlaylistInfo $i -Refresh:$Refresh
    $choices = Read-Choices (Join-Path $StatusDir "$($info.Key).keuzes.json")
    $indexDone = Read-IndexDone (Join-Path $StatusDir "$($info.Key).index.csv")
    $results = Read-Results $info.Key
    $outDir = Join-Path $MusicDir (Safe-FileName $info.Name)
    $folder = Get-FolderIndex $outDir
    $queued = Get-QueuedUris $cfg['playlists'][$i].Source
    $counts = @{ total = $info.Tracks.Count; binnen = 0; overgeslagen = 0; kiezen = 0; zoeken = 0; nietgevonden = 0; wachtrij = 0 }
    $tracks = @(foreach ($t in $info.Tracks) {
        $split = Split-Title $t.Title
        $c = $choices[$t.Uri]
        $o = [ordered]@{
            uri = $t.Uri; artist = $t.Artist; artists = $t.Artists; title = $t.Title; base = $split.Base
            version = $split.Version; length = $t.Length; preview = $t.Preview; status = ''; versie = ''; bestand = ''
            groups = @()
        }
        # 'opnieuw' = de gebruiker wil opnieuw kiezen; dan telt wat in de map staat niet
        $inFolder = if (-not $c) { Find-InFolder $t $folder }
        if ($c -and $c.status -eq 'binnen') {
            $o.status = 'binnen'; $o.versie = $c.versie; $o.bestand = $c.bestand
        } elseif (-not $c -and $indexDone["$($t.Artist)|$($t.Title)".ToLower()]) {
            $o.status = 'binnen'; $o.versie = 'automatisch'
        } elseif ($inFolder) {
            $o.status = 'binnen'; $o.versie = 'stond al in de map'; $o.bestand = $inFolder
        } elseif ($c -and $c.status -eq 'overgeslagen') {
            $o.status = 'overgeslagen'
        } elseif ($queued[$t.Uri]) {
            # staat in de wachtrij (of is nu bezig): zoeken of downloaden
            $o.status = 'wachtrij'; $o.versie = $queued[$t.Uri]
        } elseif ($results[$t.Uri]) {
            $groups = @($results[$t.Uri].groups | Where-Object { $_ } | ForEach-Object {
                [ordered]@{ label = $_.label; display = $_.display; length = $_.length; sources = $_.sources
                            free = $_.free; quality = $_.quality; score = $_.score; example = $_.example }
            })
            if ($groups.Count) { $o.status = 'kiezen'; $o.groups = $groups } else { $o.status = 'nietgevonden' }
        } else {
            $o.status = 'zoeken'
        }
        $counts[$o.status]++
        $o
    })
    return [ordered]@{
        index = $i; key = $info.Key; name = $info.Name; cover = $info.Cover; src = $cfg['playlists'][$i].Source
        outDir = (Join-Path $MusicDir (Safe-FileName $info.Name))
        limited = [bool]($info.Spotify -and -not $info.Full -and $info.Tracks.Count -ge 100)
        fromApi = [bool]$info.Full
        note = $info.Note
        counts = $counts; tracks = $tracks; outDirFiles = $folder.Files.Count
        analyse = (Read-AnalyseRapport $info.Name)
        m3u = (Write-PlaylistM3u $info $outDir)
    }
}

function Get-AppState {
    $err = Load-Config
    $lists = @(for ($i = 0; $i -lt $cfg['playlists'].Count; $i++) {
        $pl = $cfg['playlists'][$i]
        $c = $script:PlCache[$pl.Source]
        [ordered]@{
            index = $i; src = $pl.Source
            name = $(if ($pl.Name) { $pl.Name } elseif ($c) { $c.Info.Name } else { '' })
            cover = $(if ($c) { $c.Info.Cover } else { $null })
        }
    })
    return [ordered]@{
        setup = [ordered]@{
            ready = -not $err; problem = $err
            user = $cfg['soulseek-gebruiker']; hasPassword = [bool]$cfg['soulseek-wachtwoord']
            musicDir = $cfg['muziekmap']; musicDirFull = $MusicDir
            alleenFlac = (Is-Yes $cfg['alleen-flac']); timSelector = (Is-Yes $cfg['tim-selector']); netteNamen = (Is-Yes $cfg['nette-namen'])
            voorkeur = $cfg['voorkeur-versie']
            traktor = $(if ($null -eq $script:HasTraktor) { $script:HasTraktor = [bool](Find-TraktorCollection) }; $script:HasTraktor)
            spotify = $(
                $tok = Read-SpotifyToken
                $login = if (Test-Path $SpotifyLoginStatus) { try { [IO.File]::ReadAllText($SpotifyLoginStatus, $Utf8) | ConvertFrom-Json } catch { $null } }
                [ordered]@{
                    app = [bool]$HasSpotifyApp; loggedIn = [bool]($tok -and $tok.refresh_token); user = $(if ($tok) { $tok.user } else { $null })
                    login = $login; redirect = $SpotifyRedirect
                    hasId = [bool]$cfg['spotify-id']
                })
            analyse = (Get-AnalyseState)
        }
        playlists = $lists
        version = $Version
        task = (Read-TaskStatus)
        running = (Task-Running)
        queue = @($script:Queue | ForEach-Object { [ordered]@{ id = $_.id; type = $_.type; name = $_.name; count = $_.count; src = $_.src } })
    }
}

function Send-Response($ctx, [int]$code, [string]$type, [byte[]]$bytes) {
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers['Cache-Control'] = 'no-store'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Send-Json($ctx, $obj, [int]$code = 200) {
    $json = if ($null -eq $obj) { 'null' } else { $obj | ConvertTo-Json -Depth 10 -Compress }
    Send-Response $ctx $code 'application/json; charset=utf-8' $Utf8.GetBytes($json)
}

function Read-Body($ctx) {
    $reader = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    if (-not $text) { return [pscustomobject]@{} }
    return $text | ConvertFrom-Json
}

function Handle-Request($ctx, $port) {
    $req = $ctx.Request
    # Alleen deze pagina mag de server aansturen, geen andere website in je browser.
    $okHosts = "localhost:$port", "127.0.0.1:$port"
    if ($req.Headers['Host'] -notin $okHosts) { Send-Json $ctx @{ error = 'Verboden.' } 403; return }
    if ($req.HttpMethod -eq 'POST') {
        $origin = $req.Headers['Origin']
        if ($origin -and $origin -notin ($okHosts | ForEach-Object { "http://$_" })) { Send-Json $ctx @{ error = 'Verboden.' } 403; return }
        if ($req.ContentType -notlike 'application/json*') { Send-Json $ctx @{ error = 'Verwacht JSON.' } 415; return }
    }

    $path = $req.Url.AbsolutePath
    $q = $req.QueryString
    switch ("$($req.HttpMethod) $path") {
        'GET /' {
            $bytes = [IO.File]::ReadAllBytes($UiFile)
            Send-Response $ctx 200 'text/html; charset=utf-8' $bytes
        }
        'GET /ping.gif' {
            # index.html (los geopend) laadt dit als plaatje om te zien of de tool draait
            $ctx.Response.Headers['X-PlaylistFlac'] = '1'
            $gif = [Convert]::FromBase64String('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7')
            Send-Response $ctx 200 'image/gif' $gif
        }
        'GET /api/state' { Send-Json $ctx (Get-AppState) }
        'GET /api/update' { Send-Json $ctx (Get-UpdateInfo) }
        'POST /api/update' {
            $v = Install-Update
            Send-Json $ctx @{ ok = $true; version = $v }
            $script:Restart = $true
            $script:Quit = $true
        }
        'GET /api/playlist' {
            [void](Load-Config)
            Send-Json $ctx (Get-PlaylistView ([int]$q['i']) -Refresh:($q['ververs'] -eq '1'))
        }
        'POST /api/settings' {
            $b = Read-Body $ctx
            $v = [ordered]@{}
            if ($null -ne $b.user) { $v['soulseek-gebruiker'] = "$($b.user)".Trim() }
            if ($b.pass) { $v['soulseek-wachtwoord'] = "$($b.pass)".Trim() }
            if ($b.musicDir) { $v['muziekmap'] = "$($b.musicDir)".Trim() }
            if ($null -ne $b.alleenFlac) { $v['alleen-flac'] = $(if ($b.alleenFlac) { 'ja' } else { 'nee' }) }
            if ($null -ne $b.timSelector) { $v['tim-selector'] = $(if ($b.timSelector) { 'ja' } else { 'nee' }) }
            if ($null -ne $b.netteNamen) { $v['nette-namen'] = $(if ($b.netteNamen) { 'ja' } else { 'nee' }) }
            if ($b.voorkeur) { $v['voorkeur-versie'] = "$($b.voorkeur)".Trim() }
            if ($b.spotifyId) { $v['spotify-id'] = "$($b.spotifyId)".Trim() }
            if ($b.spotifySecret) { $v['spotify-secret'] = "$($b.spotifySecret)".Trim() }
            Write-Settings $v $null
            Send-Json $ctx (Get-AppState)
        }
        'POST /api/playlists/add' {
            $b = Read-Body $ctx
            [void](Load-Config)
            $src = "$($b.src)".Trim()
            $name = "$($b.name)".Trim()
            if (-not $src) { throw 'Plak eerst een Spotify-link.' }
            $ref = Get-SpotifyRef $src
            if ($ref) { $src = "https://open.spotify.com/$($ref.Type)/$($ref.Id)" }
            $info = Resolve-Playlist @{ Name = $(if ($name) { $name } else { $null }); Source = $src }
            $lists = @($cfg['playlists']) + @{ Name = $(if ($name) { $name } else { $null }); Source = $src }
            Write-Settings @{} $lists
            [void](Load-Config)
            $script:PlCache[$src] = @{ At = (Get-Date); Info = $info }
            Send-Json $ctx @{ index = $cfg['playlists'].Count - 1 }
        }
        'POST /api/playlists/remove' {
            $b = Read-Body $ctx
            [void](Load-Config)
            $i = [int]$b.index
            $lists = @(for ($j = 0; $j -lt $cfg['playlists'].Count; $j++) { if ($j -ne $i) { $cfg['playlists'][$j] } })
            Write-Settings @{} $lists
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/search' {
            $b = Read-Body $ctx
            Add-ToQueue @{ type = 'zoeken'; index = [int]$b.index; uris = @($b.uris) }
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/download' {
            $b = Read-Body $ctx
            Add-ToQueue @{ type = 'downloaden'; index = [int]$b.index; picks = @($b.picks) }
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/queue/remove' {
            $b = Read-Body $ctx
            $hit = @($script:Queue | Where-Object { $_.id -eq [int]$b.id })
            foreach ($h in $hit) { $script:Queue.Remove($h) }
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/choice' {
            $b = Read-Body $ctx
            [void](Load-Config)
            $info = Get-PlaylistInfo ([int]$b.index)
            $path = Join-Path $StatusDir "$($info.Key).keuzes.json"
            $choices = Read-Choices $path
            $t = $info.Tracks | Where-Object { $_.Uri -eq $b.uri } | Select-Object -First 1
            if ($b.action -eq 'overslaan') {
                $choices[$b.uri] = @{ status = 'overgeslagen'; titel = "$($t.Artist) - $($t.Title)" }
            } else {
                # terug naar "nog kiezen", ook als er al een versie in de map staat
                $choices[$b.uri] = @{ status = 'opnieuw'; titel = "$($t.Artist) - $($t.Title)" }
            }
            Save-Choices $choices $path
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/cancel' {
            # standaard alleen de huidige; met all ook alles wat nog in de wachtrij staat
            $b = Read-Body $ctx
            if ($b.all) { $script:Queue.Clear() }
            Stop-Task
            Pump-Queue
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/export/rekordbox' { Send-Json $ctx (Export-Rekordbox) }
        'POST /api/analyse/install' {
            Add-ToQueue @{ type = 'installeren' }
            Send-Json $ctx @{ ok = $true; running = (Task-Running) }
        }
        'POST /api/analyse' {
            # per playlist een opdracht in de wachtrij
            $b = Read-Body $ctx
            $doen = @($b.doen | Where-Object { $AnaDoen -contains $_ })
            $formaten = @($b.formaten | Where-Object { $AnaFormaten -contains $_ })
            if (-not $doen.Count -or -not $formaten.Count) { throw 'Kies wat je wilt analyseren en voor welke software.' }
            foreach ($i in @($b.indexes)) {
                Add-ToQueue @{ type = 'analyseren'; index = [int]$i; doen = $doen; formaten = $formaten; opnieuw = [bool]$b.opnieuw; hele = [bool]$b.hele }
            }
            Send-Json $ctx @{ ok = $true; running = (Task-Running) }
        }
        'POST /api/spotify/login' {
            [void](Load-Config)
            if (-not $HasSpotifyApp) { throw 'Vul eerst de Client ID en het Client secret van je Spotify-app in.' }
            if ($script:LoginProc -and -not $script:LoginProc.HasExited) { try { $script:LoginProc.Kill() } catch { } }
            $state = [guid]::NewGuid().ToString('N')
            Write-LoginStatus 'wachten' 'Spotify-pagina openen...'
            $script:LoginProc = Start-Self "-SpotifyLogin $state -UiPort $port"
            Start-Sleep -Milliseconds 600      # even laten luisteren voor Spotify terugstuurt
            Open-Url (Get-SpotifyAuthorizeUrl $state)
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/spotify/logout' {
            foreach ($p in $SpotifyTokenPath, $SpotifyLoginStatus) { if (Test-Path $p) { Remove-Item $p -Force } }
            $script:PlCache = @{}
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/reveal' {
            # alleen onze eigen exportbestanden, geen willekeurig pad van buitenaf
            $b = Read-Body $ctx
            if ($b.what -eq 'export') {
                New-Item -ItemType Directory -Force $ExportDir | Out-Null
                Open-Folder $ExportDir
            } else {
                $p = Join-Path $DataDir 'rekordbox.xml'
                if (Test-Path -LiteralPath $p) { Show-File $p }
            }
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/open' {
            $b = Read-Body $ctx
            [void](Load-Config)
            $dir = if ($null -ne $b.index) { Join-Path $MusicDir (Safe-FileName (Get-PlaylistInfo ([int]$b.index)).Name) } else { $MusicDir }
            New-Item -ItemType Directory -Force $dir | Out-Null
            Open-Folder $dir
            Send-Json $ctx @{ ok = $true }
        }
        'POST /api/quit' {
            Stop-Task
            Send-Json $ctx @{ ok = $true }
            $script:Quit = $true
        }
        default { Send-Json $ctx @{ error = 'Onbekend adres.' } 404 }
    }
}

# De link playlistflac:// laat index.html (los geopend) de tool starten.
# Windows: alleen voor deze gebruiker (HKCU), geen adminrechten nodig.
# Mac: een klein app'je PlaylistFlac.app in de map van PlaylistFlac (gemaakt met
# osacompile, dat bij macOS hoort) dat playlistflac:// afhandelt; dubbelklikken
# start de tool ook.
$ProtocolKey = 'HKCU:\Software\Classes\playlistflac'
$MacApp = Join-Path $Root 'PlaylistFlac.app'

function Register-Protocol {
    if ($OnMac) { Register-MacApp; return }
    if (-not $OnWin) { return }
    $cmd ='powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "{0}" -Link' -f $PSCommandPath
    $cmdKey = "$ProtocolKey\shell\open\command"
    if ((Test-Path $cmdKey) -and (Get-Item $cmdKey).GetValue('') -eq $cmd) { return }
    New-Item -Path $cmdKey -Force | Out-Null
    Set-Item -Path $ProtocolKey -Value 'URL:PlaylistFlac'
    New-ItemProperty -Path $ProtocolKey -Name 'URL Protocol' -Value '' -Force | Out-Null
    Set-Item -Path $cmdKey -Value $cmd
}

$LsRegister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

# Mac: PlaylistFlac.app maken (of opnieuw, als de map of PowerShell verplaatst is).
# Het app'je start dit script op de achtergrond; via playlistflac:// met -Link.
function Register-MacApp {
    $pwsh = (Get-Process -Id $PID).Path
    $sig = "$pwsh|$PSCommandPath|$Version"
    $flag = Join-Path $StatusDir 'mac-app.txt'
    if ((Test-Path -LiteralPath $MacApp) -and (Test-Path $flag) -and [IO.File]::ReadAllText($flag, $Utf8).Trim() -eq $sig) { return }
    $sh = { param($s) "'" + ($s -replace "'", "'\''") + "'" }                  # voor de shell
    $as = { param($s) '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }  # voor AppleScript
    # een app die vanuit Finder start, kent /opt/homebrew/bin en /usr/local/bin niet
    $cmd = 'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; nohup ' + (& $sh $pwsh) + ' -NoProfile -File ' + (& $sh $PSCommandPath)
    $src = @(
        'on run'
        '    do shell script ' + (& $as "$cmd >/dev/null 2>&1 &")
        'end run'
        'on open location theURL'
        '    do shell script ' + (& $as "$cmd -Link >/dev/null 2>&1 &")
        'end open location'
    ) -join "`n"
    $tmp = Join-Path $StatusDir 'PlaylistFlac.applescript'
    [IO.File]::WriteAllText($tmp, $src, $Utf8)
    if (Test-Path -LiteralPath $MacApp) { Remove-Item -LiteralPath $MacApp -Recurse -Force }
    & osacompile -o $MacApp $tmp
    if ($LASTEXITCODE) { throw 'osacompile maakte PlaylistFlac.app niet.' }
    $plist = Join-Path $MacApp 'Contents/Info.plist'
    $pb = '/usr/libexec/PlistBuddy'
    & $pb -c 'Delete :CFBundleURLTypes' $plist 2>$null
    & $pb -c 'Add :CFBundleURLTypes array' -c 'Add :CFBundleURLTypes:0 dict' -c 'Add :CFBundleURLTypes:0:CFBundleURLName string PlaylistFlac' `
          -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string playlistflac' $plist
    & $pb -c 'Set :CFBundleIdentifier local.playlistflac' $plist 2>$null
    # Info.plist aangepast: opnieuw (ad-hoc) ondertekenen, anders weigert macOS het app'je
    & codesign --force --deep --sign - $MacApp 2>$null
    if (Test-Path $LsRegister) { & $LsRegister -f $MacApp }
    Remove-Item $tmp -Force
    [IO.File]::WriteAllText($flag, $sig, $Utf8)
}

# Eenmalig een snelkoppeling 'PlaylistFlac' op het bureaublad: op Windows naar
# index.html, op een Mac naar PlaylistFlac.app. Gooi je die weg, dan komt hij
# niet terug (het vlaggetje in data\status blijft).
function Add-DesktopShortcut {
    $flag = Join-Path $StatusDir 'snelkoppeling.txt'
    if (Test-Path $flag) { return }
    if ($OnMac) {
        $lnk = Join-Path (Join-Path $HOME 'Desktop') 'PlaylistFlac.app'
        if ((Test-Path -LiteralPath $MacApp) -and -not (Test-Path -LiteralPath $lnk)) {
            New-Item -ItemType SymbolicLink -Path $lnk -Target $MacApp | Out-Null
            Say "Snelkoppeling 'PlaylistFlac' op je bureaublad gezet." Green
        }
        [IO.File]::WriteAllText($flag, "$lnk`n$((Get-Date).ToString('o'))`n", $Utf8)
        return
    }
    if (-not $OnWin) { return }
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desk 'PlaylistFlac.lnk'
    if ($desk -and -not (Test-Path -LiteralPath $lnk)) {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = $UiFile
        $sc.WorkingDirectory = $Root
        $sc.Description = 'PlaylistFlac: Spotify-playlists als FLAC via Soulseek'
        $sc.Save()
        Say "Snelkoppeling 'PlaylistFlac' op je bureaublad gezet." Green
    }
    [IO.File]::WriteAllText($flag, "$lnk`r`n$((Get-Date).ToString('o'))`r`n", $Utf8)
}

function Unregister-Protocol {
    if ($OnMac) {
        if (Test-Path -LiteralPath $MacApp) {
            if (Test-Path $LsRegister) { & $LsRegister -u $MacApp }
            Remove-Item -LiteralPath $MacApp -Recurse -Force
        }
        $flag = Join-Path $StatusDir 'mac-app.txt'
        if (Test-Path $flag) { Remove-Item $flag -Force }
        return
    }
    if ($OnWin -and (Test-Path $ProtocolKey)) { Remove-Item $ProtocolKey -Recurse -Force }
}

# Een .nml inladen wist in Traktor de cover van een track, tenzij de verwijzing
# ernaar in de .nml staat; en die staat in collection.nml zodra Traktor heeft
# opgeslagen. Daarom: is de collectie nieuwer dan een export, dan die export
# bijwerken. Op de achtergrond, een tegelijk, en de collectie wordt alleen gelezen.
# Alleen exports met een analyserapport ernaast: die heeft PlaylistFlac zelf gemaakt.
$script:SyncProc = $null
$script:SyncAt = $null
$script:SyncTried = @{}
$script:SyncFile = $null

function Sync-Exports {
    # net bijgewerkt? dan ook de kopie op het bureaublad
    if ($script:SyncFile -and $script:SyncProc -and $script:SyncProc.HasExited) {
        $done = $script:SyncFile; $script:SyncFile = $null
        # met een (nieuw)-bestand ernaast hoort dat op het bureaublad, niet de hele playlist
        $isNieuw = $done -match ' \(nieuw\)\.nml$'
        if ($script:SyncProc.ExitCode -eq 0 -and ($isNieuw -or -not (Test-Path -LiteralPath ($done -replace '\.nml$', ' (nieuw).nml')))) {
            [void](Copy-NmlToDesktop $done)
        }
    }
    if ($script:SyncAt -and ((Get-Date) - $script:SyncAt).TotalSeconds -lt 15) { return }
    $script:SyncAt = Get-Date
    if ((Task-Running) -or ($script:SyncProc -and -not $script:SyncProc.HasExited)) { return }
    if (-not ((Test-Path $AnaReady) -and (Test-Path $AnaPy) -and (Test-Path -LiteralPath $ExportDir))) { return }
    $collectie = Find-TraktorCollection
    if (-not $collectie) { return }
    $saved = (Get-Item -LiteralPath $collectie).LastWriteTime
    if (((Get-Date) - $saved).TotalSeconds -lt 5) { return }       # Traktor is misschien nog aan het schrijven
    $next = Get-ChildItem -LiteralPath $ExportDir -Filter '*.nml' -File | Where-Object {
        $_.LastWriteTime -lt $saved -and $script:SyncTried[$_.FullName] -ne $saved -and
        (Test-Path -LiteralPath ($_.FullName -replace '( \(nieuw\))?\.nml$', '.analyse.json'))
    } | Select-Object -First 1
    if (-not $next) { return }
    $script:SyncTried[$next.FullName] = $saved
    $script:SyncFile = $next.FullName
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $AnaPy
    $psi.Arguments = (@('-I', $AnaScript, '--bijwerken', $next.FullName, '--collectie', $collectie) | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:SyncProc = [Diagnostics.Process]::Start($psi)
}

# Draait PlaylistFlac al? Dan het adres daarvan, anders $null.
function Find-RunningUi {
    foreach ($port in $Ports) {
        try {
            $req = [Net.WebRequest]::Create("http://localhost:$port/ping.gif")
            $req.Timeout = 400
            $res = $req.GetResponse()
            $ours = $res.Headers['X-PlaylistFlac'] -eq '1'
            $res.Close()
            if ($ours) { return "http://localhost:$port/" }
        } catch { }
    }
    return $null
}

function Start-Ui {
    $running = Find-RunningUi
    if ($running) {
        if (-not $Link) { Open-Url $running }
        return 0
    }
    New-Item -ItemType Directory -Force $StatusDir | Out-Null
    [void](Load-Config)
    try { Register-Protocol } catch { Say "Kon de playlistflac://-koppeling niet registreren: $($_.Exception.Message)" Yellow }
    try { Add-DesktopShortcut } catch { Say "Kon geen snelkoppeling op het bureaublad zetten: $($_.Exception.Message)" Yellow }
    if (-not (Test-Path $Exe)) { Install-Sockseek }
    # Een taak die nog liep toen het venster dicht ging, is weg.
    if (Test-Path $TaskStatusPath) { Remove-Item $TaskStatusPath -Force }

    $listener = $null
    foreach ($port in $Ports) {
        $l = New-Object Net.HttpListener
        $l.Prefixes.Add("http://localhost:$port/")
        try { $l.Start(); $listener = $l; break } catch { $l.Close() }
    }
    if (-not $listener) { Say 'Geen vrije poort gevonden voor de webinterface.' Red; return 1 }

    $url = "http://localhost:$port/"
    $Host.UI.RawUI.WindowTitle = 'PlaylistFlac'
    Say ''
    Say "  PlaylistFlac $Version draait op $url" Cyan
    Say '  Laat dit venster open (minimaliseren mag); sluiten = stoppen.'
    Say ''
    # Via index.html gestart? Die pagina stuurt zichzelf al door.
    if (-not $Link) { Open-Url $url }

    $script:Quit = $false
    $script:Restart = $false
    try {
        while (-not $script:Quit) {
            $wait = $listener.BeginGetContext($null, $null)
            # wachten in stukjes, zodat Ctrl+C blijft werken
            # tussendoor de wachtrij bijhouden: is een taak klaar, dan start de volgende
            while (-not $wait.AsyncWaitHandle.WaitOne(500)) {
                Pump-Queue
                try { Sync-Exports } catch { }
            }
            $ctx = $listener.EndGetContext($wait)
            try {
                Handle-Request $ctx $port
            } catch {
                try { Send-Json $ctx @{ error = $_.Exception.Message } 400 } catch { }
            }
        }
    } finally {
        Stop-Task
        $listener.Stop()
        $listener.Close()
    }
    if ($script:Restart) {      # bijgewerkt: de nieuwe versie neemt het over; de pagina herlaadt zichzelf
        [void](Start-Self '-Link')
        Say 'Bijgewerkt. De nieuwe versie is gestart; je kunt dit venster sluiten.' Green
        return 0
    }
    Say 'Gestopt. Je kunt dit venster sluiten.'
    return 0
}

# --- start ----------------------------------------------------------------

if ($SpotifyLogin) {
    Run-SpotifyLogin $SpotifyLogin $UiPort
    exit 0
}
if ($Rekordbox) {
    $r = Export-Rekordbox
    Say "Klaar: $($r.bestand)" Green
    Say ("{0} tracks, {1} met beatgrid, {2} met key, {3} hotcues, {4} memory cues, {5} loops, {6} playlists" -f `
        $r.tracks, $r.grids, $r.keys, $r.hotcues, $r.memory, $r.loops, $r.playlists)
    if ($r.ontbreekt) { Say "$($r.ontbreekt) tracks uit Traktor staan niet meer op hun plek en zijn overgeslagen." Yellow }
    exit 0
}
if ($Afmelden) {
    Unregister-Protocol
    Say 'De playlistflac://-koppeling is weer verwijderd.' Green
    exit 0
}
if ($Taak) {
    Run-Task $Taak
    exit 0
}
if ($Console -or $Proef) {
    exit (Run-Console)
}
exit (Start-Ui)
