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
