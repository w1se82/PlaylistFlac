# PlaylistFlac - versies.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- versies herkennen ----------------------------------------------------

$VersionWords = '\b(mix|edit|remix|rmx|version|dub|rework|bootleg|vip|live|instrumental|acapella|cappella|extended|original|club|radio|remaster|remastered|re-?edit|flip|cut)\b'
# woorden die zeggen wat voor versie het is, niet van wie
$GenericWords = 'mix|edit|remix|rmx|version|dub|rework|bootleg|vip|extended|original|club|radio|re-?edit|flip|cut|the|feat|ft|and|vs|x|remaster|remastered|\d{4}'
# woorden die een ander nummer maken dan het origineel
$OtherSongWords = '\b(remix|rmx|rework|bootleg|flip|vip|re-?edit|live|acapella|instrumental)\b'

function Norm($s) {
    return ("$s".ToLowerInvariant() -replace '[''\u2019]', '' -replace '[^\p{L}\p{N}]+', ' ').Trim()
}

# "Nutcase - Mark Eteson Remix" -> Base "Nutcase", Version "Mark Eteson Remix"
function Split-Title($title) {
    $base = $title; $version = ''
    if ($base -match '^(?<b>.+?)\s+-\s+(?<v>.+)$') { $base = $Matches.b; $version = $Matches.v }
    foreach ($m in [regex]::Matches($base, '[\(\[]([^\)\]]*)[\)\]]')) {
        if (-not $version -and $m.Groups[1].Value -match $VersionWords) { $version = $m.Groups[1].Value }
    }
    $base = ($base -replace '\s*[\(\[][^\)\]]*[\)\]]', '').Trim()
    return @{ Base = $base; Version = $version.Trim() }
}

# Naam en extensie van een bestand op Soulseek. Niet via [IO.Path]: die weigert in
# Windows PowerShell tekens als " en | , en die komen op andermans Mac of Linux
# gewoon voor in bestandsnamen.
function Get-RemoteName($path) { return ("$path" -split '[\\/]')[-1] }
function Get-RemoteStem($path) {
    $n = Get-RemoteName $path; $i = $n.LastIndexOf('.')
    if ($i -ge 0) { return $n.Substring(0, $i) } else { return $n }
}
function Get-RemoteExt($path) {
    $n = Get-RemoteName $path; $i = $n.LastIndexOf('.')
    if ($i -ge 0) { return $n.Substring($i) } else { return '' }
}

# Haalt "Extended Mix", "Mark Eteson Remix" e.d. uit een Soulseek-bestandsnaam.
function Get-FileVersion($filename, $base) {
    $name = (Get-RemoteStem $filename) -replace '_', ' '
    # reclame van downloadsites eruit: "[www.dj-promo.org]", "-www.groovytunes.org"
    $name = $name -replace '(?i)\s*-?\s*[\[\(]?\s*www\.[^\s\]\)]+\s*[\]\)]?', '' `
                  -replace '(?i)\s*[\[\(]\s*[a-z0-9-]+\.(org|com|net|ru|info|to|eu|nl|de)\s*[\]\)]', ''
    $parts = @([regex]::Matches($name, '[\(\[]([^\)\]]*)[\)\]]') | ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -match $VersionWords -and $_ -notmatch '^\s*(feat|ft|with)\b' })
    if (-not $parts.Count) {
        # zonder haakjes: "artiest-titel-original_mix" of "Titel - Radio Edit":
        # neem wat er na de titel komt
        $flat = Norm $name
        $nb = Norm $base
        $at = $flat.IndexOf($nb)
        if ($at -ge 0) {
            $rest = $flat.Substring($at + $nb.Length).Trim()
            if ($rest -match $VersionWords) { $parts = @($rest) }
        }
    }
    $label = Norm ($parts -join ' ')
    $label = $label -replace '\brmx\b', 'remix' -replace '\b(flac|wav|web|promo|vinyl|cd|\d+ ?(bit|khz|kbps))\b', ''
    $label = ($label -replace '\s+', ' ').Trim()
    if ($label -in 'original', 'extended', 'club') { $label += ' mix' }
    # "X Remix (Extended Mix)" is hetzelfde als "X Extended Remix"
    $label = $label -replace '^(.+) remix extended mix$', '$1 extended remix'
    return $label
}

function Format-Length($sec) {
    if (-not $sec) { return '  ?  ' }
    return '{0}:{1:00}' -f [int][math]::Floor($sec / 60), ($sec % 60)
}

# Groepeert zoekresultaten per versie en zet de beste keuze bovenaan.
function Group-Versions($results, $track) {
    $split = Split-Title $track.Title
    $nb = Norm $split.Base
    $ownWords = @((Norm $split.Version) -split ' ' | Where-Object { $_ -and $_ -notmatch "^($GenericWords)$" })

    # titel moet in de bestandsnaam staan, artiest ergens in het pad (map of naam);
    # spaties tellen niet mee, zodat "A.D.H.S." ook "ADHS" vindt
    $nbFlat = $nb -replace ' ', ''
    # alle artiesten van het nummer tellen mee: bij "Oxia, Space 92" staat soms
    # Space 92 vooraan in de bestandsnaam
    $artistsFlat = @(@($track.Artist) + @("$($track.Artists)" -split ',\s*') |
        ForEach-Object { (Norm $_) -replace ' ', '' } | Where-Object { $_ } | Select-Object -Unique)
    $hits = @($results | Where-Object { ((Norm (($_.File.Filename -split '[\\/]')[-1])) -replace ' ', '').Contains($nbFlat) })
    if (-not $hits.Count) { $hits = @($results) }
    if ($artistsFlat.Count) {
        $withArtist = @($hits | Where-Object {
            $path = (Norm $_.File.Filename) -replace ' ', ''
            @($artistsFlat | Where-Object { $path.Contains($_) }).Count -gt 0
        })
        if ($withArtist.Count) { $hits = $withArtist }
    }

    $groups = [ordered]@{}
    $i = 0
    foreach ($r in $hits) {
        $label = Get-FileVersion $r.File.Filename $split.Base
        if (-not $groups.Contains($label)) {
            $groups[$label] = @{ Label = $label; Results = New-Object System.Collections.ArrayList; Rank = $i }
        }
        [void]$groups[$label].Results.Add($r)
        $i++
    }

    # Een bestand zonder versienaam met (bijna) dezelfde lengte als een benoemde
    # versie is vrijwel zeker die versie: "01 - Fluppe.flac" van 5:55 = de Original Mix.
    if ($groups.Contains('')) {
        $median = {
            param($res)
            $l = @($res | ForEach-Object { $_.File.Length } | Where-Object { $_ } | Sort-Object)
            if ($l.Count) { $l[[int][math]::Floor($l.Count / 2)] } else { 0 }
        }
        $named = @($groups.Values | Where-Object { $_.Label } | ForEach-Object { @{ G = $_; Len = (& $median $_.Results) } })
        $keep = New-Object System.Collections.ArrayList
        foreach ($r in $groups[''].Results) {
            $len = $r.File.Length
            $target = if ($len) {
                $named | Where-Object { $_.Len -and [math]::Abs($_.Len - $len) -le 3 } |
                    Sort-Object { $_.G.Results.Count } -Descending | Select-Object -First 1
            }
            if ($target) { [void]$target.G.Results.Add($r) } else { [void]$keep.Add($r) }
        }
        if ($keep.Count) { $groups[''].Results = $keep } else { $groups.Remove('') }
    }

    $out = foreach ($g in $groups.Values) {
        $score = 0
        if ($ownWords.Count) {
            # Spotify-versie is een remix van iemand: die moet het zijn
            $hit = @($ownWords | Where-Object { " $($g.Label) " -like "* $_ *" }).Count
            if ($hit -eq $ownWords.Count) { $score += 1000 } else { $score -= 1000 }
        } elseif ($g.Label -match $OtherSongWords) {
            $score -= 500
        }
        for ($p = 0; $p -lt $Prefs.Count; $p++) {
            if ($g.Label -like "*$($Prefs[$p])*") { $score += 100 - $p * 10; break }
        }
        $lengths = @($g.Results | ForEach-Object { $_.File.Length } | Where-Object { $_ } | Sort-Object)
        $users = @($g.Results | ForEach-Object { $_.User.Username } | Select-Object -Unique)
        $best = $g.Results[0].File
        $quality = (Get-RemoteExt $best.Filename).TrimStart('.').ToUpper()
        if ($best.BitDepth -and $best.SampleRate) { $quality += " $($best.BitDepth)/$([math]::Round($best.SampleRate / 1000, 1))" }
        elseif ($best.BitRate) { $quality += " $($best.BitRate)" }
        # Bronnen om te proberen: een per gebruiker, eerst wie een vrij uploadslot
        # heeft (anders kom je in een wachtrij), dan de snelste.
        $seenUsers = @{}
        $cands = @()
        $order = 0
        foreach ($r in $g.Results) {
            $order++
            if ($seenUsers[$r.User.Username]) { continue }
            $seenUsers[$r.User.Username] = $true
            $cands += [pscustomobject]@{
                u = $r.User.Username; f = $r.File.Filename; size = $r.File.Size
                free = [bool]$r.User.HasFreeUploadSlot; speed = [double]$r.User.UploadSpeed; order = $order
            }
        }
        $freeCount = @($cands | Where-Object { $_.free }).Count
        $cands = @($cands | Sort-Object @{ e = 'free'; Descending = $true }, @{ e = 'speed'; Descending = $true }, order |
            Select-Object -First 8)
        [pscustomobject]@{
            Label   = $g.Label
            Display = $(if ($g.Label) { (Get-Culture).TextInfo.ToTitleCase($g.Label) } else { '(zonder aanduiding)' })
            Length  = $(if ($lengths.Count) { $lengths[[int][math]::Floor($lengths.Count / 2)] } else { 0 })
            Sources = $users.Count
            Free    = $freeCount
            Quality = $quality
            Score   = $score
            Rank    = $g.Rank
            Candidates = $cands
        }
    }
    return @($out | Sort-Object @{ e = 'Score'; Descending = $true }, @{ e = 'Free'; Descending = $true }, @{ e = 'Sources'; Descending = $true }, Rank)
}
