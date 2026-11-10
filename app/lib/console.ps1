# PlaylistFlac - console.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
