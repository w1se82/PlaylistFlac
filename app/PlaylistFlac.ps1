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
#   ui\         stijl en scripts van de interface (app.css, app.js, rondleiding.js, demo.js)
#   app\        dit script, Start.cmd (Windows), Start.command (Mac), Start.sh (Linux), sockseek (app\bin)
#   app\lib\    de onderdelen van dit script, hieronder op volgorde ingeladen
#   data\       instellingen.ini en status; blijft staan bij een update van app\
#   tests\      controles voor de ontwikkelaar (gaan niet mee in de zip)
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
#   -Afmelden  haalt de playlistflac://-koppeling weer weg (Windows, Mac, Linux)
#   -Rekordbox maakt data\rekordbox.xml uit de Traktor-collectie (zie Export-Rekordbox)
#   -Stil      (voor testen) start de webinterface zonder playlistflac://-koppeling,
#              snelkoppeling of browser
#
# De interface zonder server bekijken, met verzonnen playlists: open
# index.html?demo in de browser (zie ui\demo.js).
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
    [int]$UiPort,
    [switch]$Stil,
    [string]$Taal            # intern: nl of en, voor -SpotifyLogin (een taak krijgt hem via de opdracht)
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
$MainScript = $PSCommandPath      # in app\lib is $PSCommandPath het lib-bestand, niet dit script
$LibDir    = Join-Path $AppDir 'lib'
$Root      = Split-Path $AppDir
$UiDir     = Join-Path $Root 'ui'
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
$Version   = '1.5.1-beta'     # ook in README.md en README.nl.md; de interface leest hem uit /api/state
$UpdateRepo = 'w1se82/PlaylistFlac'     # hier haalt de updateknop nieuwe versies vandaan
# analyse: het script staat in app\analyse, Python met PyTorch per computer in data\analyse
$AnaScript = Join-Path (Join-Path $AppDir 'analyse') 'analyse.py'
$AnaDir    = Join-Path $DataDir 'analyse'
$AnaPy     = if ($OnWin) { Join-Path $AnaDir 'venv\Scripts\python.exe' } else { Join-Path $AnaDir 'venv/bin/python' }
$AnaReady  = Join-Path $AnaDir 'klaar.txt'
$ExportDir = Join-Path $DataDir 'export'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }


# --- onderdelen -------------------------------------------------------------
# Volgorde maakt uit: later ingeladen onderdelen gebruiken variabelen van eerdere.
# Dot-source in de scriptscope, zodat $script:-variabelen gedeeld blijven.
$LibParts = 'taal', 'platform', 'release', 'instellingen', 'soulseek', 'spotify', 'versies', 'playlist',
            'console', 'taak', 'rekordbox', 'analyse', 'update', 'rondleiding', 'server', 'koppeling'
foreach ($part in $LibParts) { . (Join-Path $LibDir "$part.ps1") }
# taal van meldingen tot de interface iets anders zegt (zie app\lib\taal.ps1)
$script:Lang = if ($Taal -in 'nl', 'en') { $Taal } else { Get-OsLang }

if ($Inpakken) {
    # in release\ van de projectmap; die map zelf gaat niet mee in de zip
    $releaseDir = Join-Path $Root 'release'
    New-Item -ItemType Directory -Force $releaseDir | Out-Null
    $zip = Join-Path $releaseDir "PlaylistFlac-$Version.zip"
    # via een tijdelijke kopie, zodat bin (115 MB) en data (wachtwoord) er niet in komen
    $stage = Join-Path ([IO.Path]::GetTempPath()) "PlaylistFlac-inpakken-$PID"
    $pkg = Join-Path $stage 'PlaylistFlac'
    New-Item -ItemType Directory -Force (Join-Path $pkg 'app') | Out-Null
    Copy-Item (Join-Path $Root 'index.html'), (Join-Path $Root 'README.md'), (Join-Path $Root 'README.nl.md') $pkg
    $docs = Join-Path $Root 'docs'
    if (Test-Path $docs) { Copy-Item $docs (Join-Path $pkg 'docs') -Recurse }
    New-Item -ItemType Directory -Force (Join-Path $pkg 'ui') | Out-Null
    Copy-Item (Join-Path $UiDir '*') (Join-Path $pkg 'ui') -Include '*.css', '*.js'
    Copy-Item (Join-Path $AppDir 'PlaylistFlac.ps1'), (Join-Path $AppDir 'Start.cmd'), (Join-Path $AppDir 'Start.command'), (Join-Path $AppDir 'Start.sh'), $IniExample (Join-Path $pkg 'app')
    New-Item -ItemType Directory -Force (Join-Path $pkg 'app\lib') | Out-Null
    foreach ($part in $LibParts) { Copy-Item (Join-Path $LibDir "$part.ps1") (Join-Path $pkg 'app\lib') }
    New-Item -ItemType Directory -Force (Join-Path $pkg 'app\analyse') | Out-Null
    Copy-Item (Join-Path $AppDir 'analyse\analyse.py'), (Join-Path $AppDir 'analyse\model.json') (Join-Path $pkg 'app\analyse')
    Write-ReleaseZip $stage $zip
    Remove-Item $stage -Recurse -Force
    Say "Klaar: $zip" Green
    Say 'Zonder data\ en app\bin - je wachtwoord en je status zitten er niet in.'
    return
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
