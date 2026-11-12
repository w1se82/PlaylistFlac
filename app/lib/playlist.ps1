# PlaylistFlac - playlist.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
            throw (L "Spotify-playlist niet te lezen ($($_.Exception.Message)). Is hij openbaar? Prive-playlists kan de tool niet zien." "Can't read the Spotify playlist ($($_.Exception.Message)). Is it public? The tool can't see private playlists.")
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
    throw (L "Snap deze regel niet: $src. Verwacht een Spotify-link (playlist of album) of het pad naar een CSV." "Don't understand this line: $src. Expected a Spotify link (playlist or album) or the path to a CSV.")
}
