# PlaylistFlac - rekordbox.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

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
