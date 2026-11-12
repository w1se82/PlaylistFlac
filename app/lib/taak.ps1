# PlaylistFlac - taak.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
    # in de taal van de interface die de taak startte
    if ($task.lang -in 'nl', 'en') { $script:Lang = $task.lang }
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
            Add-TaskLog (L 'sockseek ophalen bij GitHub (eenmalig, ~115 MB)...' 'Fetching sockseek from GitHub (once, ~115 MB)...')
            Install-Sockseek
        }
        Update-Task @{ phase = 'verbinden' } -Force
        Add-TaskLog (L 'Verbinden met de Soulseek-server...' 'Connecting to the Soulseek server...')
        if (-not (Test-Soulseek)) { Add-TaskLog (L 'Soulseek-server niet bereikbaar' 'Soulseek server not reachable'); throw (L $NoSoulseekMsg $NoSoulseekMsgEn) }
        Add-TaskLog (L 'Soulseek-server bereikbaar' 'Soulseek server reachable')
        Add-TaskLog (L 'Playlist ophalen bij Spotify' 'Fetching playlist from Spotify')

        $pl = $cfg['playlists'][[int]$task.index]
        $info = Resolve-Playlist $pl
        Update-Task @{ name = $info.Name } -Force
        $byUri = @{}
        foreach ($t in $info.Tracks) { $byUri[$t.Uri] = $t }

        if ($task.type -eq 'zoeken') {
            $tracks = @($task.uris | ForEach-Object { $byUri[$_] } | Where-Object { $_ })
            if (-not $tracks.Count) { throw (L 'Geen nummers om te zoeken.' 'No tracks to search.') }
            Add-TaskLog (L "$($tracks.Count) nummer(s) zoeken op Soulseek" "Searching $($tracks.Count) track(s) on Soulseek")
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
                    Add-TaskLog ((L 'Overgeslagen' 'Skipped') + ": $($tracks[$i].Artist) - $($tracks[$i].Title): $($_.Exception.Message)")
                }
                if ($groups.Count) { $found++ }
                $results[$tracks[$i].Uri] = @{ at = (Get-Date).ToString('o'); groups = $groups }
            }
            Save-Results $results $info.Key
            $msg = L "$found van $($tracks.Count) gevonden. Kies nu de versies." "Found $found of $($tracks.Count). Now choose the versions."
            if ($found -lt $tracks.Count) { $msg = L "$found van $($tracks.Count) gevonden; de rest staat onder Niet gevonden." "Found $found of $($tracks.Count); the rest is under Not found." }
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
            if (-not $picks.Count) { throw (L 'Niets om te downloaden; zoek eerst opnieuw.' 'Nothing to download; search again first.') }
            $outDir = Join-Path $MusicDir (Safe-FileName $info.Name)
            Add-TaskLog (L "$($picks.Count) bestand(en) downloaden naar $outDir" "Downloading $($picks.Count) file(s) to $outDir")
            Download-Picks $picks $tmp
            $ok = Save-Picks $picks $outDir (Join-Path $StatusDir "$($info.Key).keuzes.json")
            [void](Write-PlaylistM3u $info $outDir)
            $msg = L "$ok van $($picks.Count) bestand(en) binnen." "$ok of $($picks.Count) file(s) downloaded."
            if ($ok -lt $picks.Count) { $msg += L ' De rest had geen bereikbare bron; probeer het later nog eens.' ' The rest had no reachable source; try again later.' }
            Update-Task @{ state = 'klaar'; message = $msg; done = $ok } -Force
        }
    } catch {
        Update-Task @{ state = 'fout'; message = $_.Exception.Message } -Force
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
