# PlaylistFlac - soulseek.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
