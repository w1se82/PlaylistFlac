# PlaylistFlac - instellingen.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
        return (L "versie-kiezen = $Mode snap ik niet; kies vragen, automatisch of uit." "versie-kiezen = $Mode is not understood; choose vragen, automatisch or uit.")
    }
    if (-not $cfg['soulseek-gebruiker'] -or -not $cfg['soulseek-wachtwoord']) {
        return (L 'Vul eerst een Soulseek-naam en -wachtwoord in.' 'Fill in a Soulseek name and password first.')
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
