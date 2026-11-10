# PlaylistFlac - spotify.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
