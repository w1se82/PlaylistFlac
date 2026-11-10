# PlaylistFlac - server.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
        rondleiding = (Read-Rondleiding)
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
    # stijl en scripts van de interface: alleen losse bestanden direct in ui\
    if ($req.HttpMethod -eq 'GET' -and $path -match '^/ui/[a-z0-9-]+\.(css|js)$') {
        $file = Join-Path $UiDir ($path.Substring(4))
        if (-not (Test-Path -LiteralPath $file)) { Send-Json $ctx @{ error = 'Onbekend adres.' } 404; return }
        $type = if ($Matches[1] -eq 'css') { 'text/css; charset=utf-8' } else { 'text/javascript; charset=utf-8' }
        Send-Response $ctx 200 $type ([IO.File]::ReadAllBytes($file))
        return
    }
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
        'POST /api/rondleiding' {
            # {seen: 'id'} onthoudt een uitleg, {reset: true} laat ze weer zien, {off: true} zet ze uit
            Send-Json $ctx (Update-Rondleiding (Read-Body $ctx))
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
    # net bijgewerkt? dan ook de kopie op het bureaublad, maar alleen als die er nog
    # staat: anders komt na elke keer opslaan in Traktor elke playlist op het bureaublad.
    if ($script:SyncFile -and $script:SyncProc -and $script:SyncProc.HasExited) {
        $done = $script:SyncFile; $script:SyncFile = $null
        # met een (nieuw)-bestand ernaast hoort dat op het bureaublad, niet de hele playlist
        $isNieuw = $done -match ' \(nieuw\)\.nml$'
        $desk = Get-DesktopNml $done
        if ($script:SyncProc.ExitCode -eq 0 -and $desk -and (Test-Path -LiteralPath $desk) -and
            ($isNieuw -or -not (Test-Path -LiteralPath ($done -replace '\.nml$', ' (nieuw).nml')))) {
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
        if (-not $Link -and -not $Stil) { Open-Url $running }
        return 0
    }
    New-Item -ItemType Directory -Force $StatusDir | Out-Null
    [void](Load-Config)
    # -Stil: niets aan de computer veranderen (testen vanuit een kopie)
    if (-not $Stil) {
        try { Register-Protocol } catch { Say "Kon de playlistflac://-koppeling niet registreren: $($_.Exception.Message)" Yellow }
        try { Add-DesktopShortcut } catch { Say "Kon geen snelkoppeling op het bureaublad zetten: $($_.Exception.Message)" Yellow }
    }
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
    if (-not $Link -and -not $Stil) { Open-Url $url }

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
