# PlaylistFlac - analyse.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- analyse (BPM, beatgrid, cues, key) --------------------------------------
#
# Optioneel. Eenmalig installeren zet Python-pakketten (PyTorch, librosa en
# Beat This!) in data\analyse\venv; dat is ruim 1 GB. Daarna schrijft
# app\analyse\analyse.py per playlist een .nml (Traktor) en een rekordbox.xml
# naar data\export. De muziekbestanden zelf worden alleen gelezen.

$BeatThisUrl = 'https://github.com/CPJKU/beat_this/archive/refs/tags/v1.1.0.zip'
$AnaDoen = 'grid', 'cues', 'key', 'keyschatting', 'energie'
$AnaFormaten = 'traktor', 'rekordbox'

# Python 3.10 of nieuwer: liefst een versie waarmee de analyse getest is (via de
# py-launcher), anders de nieuwste die er is, dan python op het PATH. Op een Mac
# python3.13 enz.; de python3 die macOS zelf meebrengt is 3.9 en valt dus af.
function Find-Python {
    $tries = if ($OnWin) { @(@('py', '-3.13'), @('py', '-3.12'), @('py', '-3.11'), @('py', '-3.10'), @('py', '-3'), @('python')) }
             else {
                 $dirs = '/Library/Frameworks/Python.framework/Versions/{0}/bin/python{0}', '/opt/homebrew/bin/python{0}', '/usr/local/bin/python{0}'
                 @(foreach ($v in '3.13', '3.12', '3.11', '3.10') { , @("python$v"); foreach ($d in $dirs) { , @($d -f $v) } }) + @(, @('python3'))
             }
    foreach ($c in $tries) {
        $exe = $c[0]; $pre = @($c | Select-Object -Skip 1)
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $out = @(& $exe @pre -c 'import sys; print(sys.executable); print(sys.version_info[0] * 100 + sys.version_info[1])' 2>$null)
        } catch { continue }
        if ($out.Count -ge 2 -and "$($out[1])" -match '^\d+$' -and [int]$out[1] -ge 310 -and (Test-Path -LiteralPath $out[0])) {
            return @{ Path = "$($out[0])"; Version = ('{0}.{1}' -f [math]::Floor([int]$out[1] / 100), ([int]$out[1] % 100)) }
        }
    }
    return $null
}

function Get-AnalyseState {
    # Python zoeken kost een fractie van een seconde; niet bij elke poll opnieuw
    if (-not $script:PyAt -or (-not $script:PyInfo -and ((Get-Date) - $script:PyAt).TotalSeconds -gt 15)) {
        $script:PyInfo = Find-Python; $script:PyAt = Get-Date
    }
    return [ordered]@{
        installed = [bool]((Test-Path $AnaReady) -and (Test-Path $AnaPy))
        python = $(if ($script:PyInfo) { $script:PyInfo.Version } else { $null })
        exportDir = $ExportDir
    }
}

function Last-Lines($text, [int]$n = 3) {
    return ((@("$text" -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last $n) -join ' / ')
}

# Draait een programma en geeft elke regel van stdout aan $OnLine. stderr wordt
# apart (en zonder vast te lopen) bewaard voor een eventuele foutmelding.
function Invoke-Logged([string]$FilePath, [string[]]$ArgList, [scriptblock]$OnLine) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $psi.EnvironmentVariables['TORCH_HOME'] = (Join-Path $AnaDir 'torch')
    $p = [Diagnostics.Process]::Start($psi)
    $err = $p.StandardError.ReadToEndAsync()
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        if ($line.Trim()) { & $OnLine $line }
    }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Err = $err.Result }
}

function Run-AnalyseInstall {
    Update-Task @{ name = 'Analyse'; phase = 'installeren'; total = 4; done = 0 } -Force
    $py = Find-Python
    if (-not $py) {
        if ($OnWin) { throw 'Python niet gevonden. Installeer Python 3 van python.org (vink "Add python.exe to PATH" aan) en probeer het daarna opnieuw.' }
        throw 'Python niet gevonden. Installeer Python 3.13 van python.org (de macOS-installer) en probeer het daarna opnieuw.'
    }
    Add-TaskLog "Python $($py.Version) gevonden: $($py.Path)"
    New-Item -ItemType Directory -Force $AnaDir | Out-Null
    if (Test-Path $AnaReady) { Remove-Item $AnaReady -Force }
    $pipLog = { param($l) if ($l -match '^(Collecting|Successfully|ERROR)') { Add-TaskLog $l.Trim() } }
    if (-not (Test-Path $AnaPy)) {
        Add-TaskLog 'Eigen Python-omgeving maken in data\analyse'
        $r = Invoke-Logged $py.Path @('-m', 'venv', (Join-Path $AnaDir 'venv')) $pipLog
        if ($r.Code) { throw "Python-omgeving maken mislukte: $(Last-Lines $r.Err)" }
    }
    Update-Task @{ done = 1 } -Force
    $pip = @('-m', 'pip', 'install', '--disable-pip-version-check', '--progress-bar', 'off')
    Add-TaskLog 'PyTorch installeren (ongeveer 800 MB, dit duurt even)'
    # Windows: de versie zonder videokaart-ondersteuning (kleiner). Een Mac haalt
    # PyTorch gewoon van PyPI; die heeft geen aparte cpu-variant.
    $torch = @('torch', 'torchaudio') + $(if ($OnMac) { @() } else { @('--index-url', 'https://download.pytorch.org/whl/cpu') })
    $r = Invoke-Logged $AnaPy ($pip + $torch) $pipLog
    if ($r.Code) { throw "PyTorch installeren mislukte: $(Last-Lines $r.Err)" }
    Update-Task @{ done = 2 } -Force
    Add-TaskLog 'librosa, Beat This! en de rest installeren'
    $r = Invoke-Logged $AnaPy ($pip + @('librosa', 'soundfile', 'soxr', 'einops', 'rotary-embedding-torch', 'mutagen', 'certifi', $BeatThisUrl)) $pipLog
    if ($r.Code) { throw "Installeren mislukte: $(Last-Lines $r.Err)" }
    Update-Task @{ done = 3 } -Force
    Add-TaskLog 'Controleren en het Beat This!-model ophalen (80 MB)'
    $r = Invoke-Logged $AnaPy @('-I', $AnaScript, '--check') { param($l) try { Add-TaskLog ($l | ConvertFrom-Json).msg } catch { } }
    if ($r.Code) { throw "Controle mislukte: $(Last-Lines $r.Err)" }
    [IO.File]::WriteAllText($AnaReady, "PlaylistFlac $Version`r`n$((Get-Date).ToString('o'))`r`n", $Utf8)
    Update-Task @{ done = 4; state = 'klaar'; message = 'De analyse is geinstalleerd. Kies nu Analyseren & exporteren.' } -Force
}

# Muziekbestanden van een playlist: in de volgorde van de .m3u8 (Spotify-volgorde),
# anders alles in de map op naam.
function Get-PlaylistFiles($name) {
    $dir = Join-Path $MusicDir (Safe-FileName $name)
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $m3u = @(Read-M3u (Join-Path $dir ((Safe-FileName $name) + '.m3u8')) | Where-Object { Test-Path -LiteralPath $_ })
    $files = if ($m3u.Count) { $m3u } else {
        @(Get-ChildItem -LiteralPath $dir -File | Sort-Object Name | ForEach-Object { $_.FullName })
    }
    return @($files | Where-Object { $_ -match '\.(flac|mp3|wav|aiff?|m4a)$' })
}

function Run-Analyse($task) {
    if (-not ((Test-Path $AnaReady) -and (Test-Path $AnaPy))) { throw 'De analyse is nog niet geinstalleerd.' }
    [void](Load-Config)
    $pl = $cfg['playlists'][[int]$task.index]
    $name = if ($pl.Name) { $pl.Name } elseif ($task.name -and $task.name -ne 'playlist') { $task.name } else { (Resolve-Playlist $pl).Name }
    Update-Task @{ name = $name; phase = 'analyseren' } -Force
    $files = @(Get-PlaylistFiles $name)
    if (-not $files.Count) { throw "Geen muziek gevonden in de map van $name. Download eerst wat nummers." }
    $doen = @($task.doen | Where-Object { $AnaDoen -contains $_ })
    $formaten = @($task.formaten | Where-Object { $AnaFormaten -contains $_ })
    if (-not $doen.Count -or -not $formaten.Count) { throw 'Kies wat je wilt analyseren en voor welke software.' }
    Update-Task @{ total = $files.Count; current = [IO.Path]::GetFileNameWithoutExtension($files[0]) } -Force
    Add-TaskLog ("{0} tracks analyseren: {1}" -f $files.Count, ($doen -join ', '))

    New-Item -ItemType Directory -Force $ExportDir | Out-Null
    $list = Join-Path $StatusDir 'analyse-lijst.txt'
    [IO.File]::WriteAllLines($list, [string[]]$files, $Utf8)
    $base = Join-Path $ExportDir (Safe-FileName $name)
    $out = @{}
    $argList = @('-I', $AnaScript, '--lijst', $list, '--naam', $name, '--doen', ($doen -join ','), '--rapport', "$base.analyse.json")
    if ($formaten -contains 'traktor') { $out.nml = "$base.nml"; $argList += @('--nml', $out.nml) }
    # Standaard alleen de nieuw geanalyseerde tracks naar Traktor: een import zet
    # anders de cues en het grid van de hele playlist terug, ook wat je zelf had verschoven.
    $nieuwNml = "$base (nieuw).nml"
    if ($out.nml -and -not $task.hele) { $argList += @('--nml-nieuw', $nieuwNml) }
    elseif (Test-Path -LiteralPath $nieuwNml) { Remove-Item -LiteralPath $nieuwNml -Force }
    if ($formaten -contains 'rekordbox') { $out.rekordbox = "$base (rekordbox).xml"; $argList += @('--rekordbox', $out.rekordbox) }
    # alleen lezen: bij het inladen zou Traktor anders de cover, het genre enz. kwijtraken
    $collectie = Find-TraktorCollection
    if ($collectie) { $argList += @('--collectie', $collectie) }
    $argList += @('--cache', (Join-Path $ExportDir 'analyse-cache.json'))
    if ($task.opnieuw) { $argList += '--opnieuw' }

    $st = @{ ok = 0; bewaard = 0; fout = 0; onzeker = 0; nalopen = 0; nieuw = 0 }
    $onLine = {
        param($l)
        try { $m = $l | ConvertFrom-Json } catch { return }
        if ($m.t -eq 'klaar') { $st.nieuw = [int]$m.nieuw; return }
        $next = if ([int]$m.i -lt $files.Count) { [IO.Path]::GetFileNameWithoutExtension($files[[int]$m.i]) } else { '' }
        if ($m.t -eq 'log') {
            Add-TaskLog $m.msg
        } elseif ($m.t -eq 'track' -and $m.bewaard) {
            $st.bewaard++
            Add-TaskLog ('Al geanalyseerd, overgeslagen: {0}' -f [IO.Path]::GetFileNameWithoutExtension($m.naam))
            Update-Task @{ done = [int]$m.i; current = $next } -Force
        } elseif ($m.t -eq 'track') {
            $st.ok++
            $bits = @()
            if ($m.bpm) { $bits += ('{0} BPM' -f ([double]$m.bpm).ToString('0.00', $Inv)) }
            if ($m.key) { $bits += "key $($m.key)" + $(if ($m.key_bron -eq 'geschat') { ' (geschat)' } else { ' (uit tags)' }) }
            if ($m.energy) { $bits += "energy $($m.energy) ($($m.kleur))" + $(if ($m.energy_bron -eq 'tags') { ' uit tags' } else { '' }) }
            if ($m.cues) { $bits += "$($m.cues) cues" }
            if ($m.onzeker) { $st.onzeker++ }
            if ($m.nalopen) { $bits += 'even nalopen'; $st.nalopen++ }
            if (-not $bits.Count) { $bits += 'niets gevonden' }
            Add-TaskLog ('Geanalyseerd: {0} - {1}' -f [IO.Path]::GetFileNameWithoutExtension($m.naam), ($bits -join ', '))
            Update-Task @{ done = [int]$m.i; current = $next } -Force
        } elseif ($m.t -eq 'fout') {
            $st.fout++
            Add-TaskLog "Mislukt: $($m.naam) - $($m.msg)"
            Update-Task @{ done = [int]$m.i; current = $next } -Force
        }
    }
    $r = Invoke-Logged $AnaPy $argList $onLine
    if ($r.Code) { throw "De analyse stopte met een fout: $(Last-Lines $r.Err)" }
    $msg = if ($st.bewaard) { "$($st.ok) tracks geanalyseerd, $($st.bewaard) overgeslagen omdat ze al klaar waren." } else { "$($st.ok) van $($files.Count) tracks geanalyseerd." }
    if ($st.fout) { $msg += " Bij $($st.fout) mislukt." }
    if ($st.nalopen) { $msg += " Bij $($st.nalopen) staat iets om na te lopen: zie Analyse bij de playlist." }
    $msg += ' Klaar in data\export: ' + ((@($out.Values) | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ' en ') + '.'
    if ($out.nml) {
        try {
            $volgorde = ' Eerst de bestanden in Traktor slepen en Traktor afsluiten, pas daarna importeren (kies dan Playlist).'
            if ($task.hele) {
                $desk = Copy-NmlToDesktop $out.nml
                if ($desk) { $msg += " Voor Traktor staat de hele playlist op je bureaublad: $([IO.Path]::GetFileName($desk))." + $volgorde }
            } elseif ($st.nieuw) {
                $desk = Copy-NmlToDesktop $nieuwNml
                if ($desk) { $msg += " Voor Traktor staan de $($st.nieuw) nieuwe tracks op je bureaublad: $([IO.Path]::GetFileName($desk)). De rest blijft in Traktor zoals hij is." + $volgorde }
            } else {
                Remove-DesktopNml $out.nml     # anders importeer je per ongeluk de vorige keer opnieuw
                $msg += ' Geen nieuwe tracks, dus niets om in Traktor te importeren.'
            }
        } catch { Add-TaskLog "Kon de .nml niet op het bureaublad zetten: $($_.Exception.Message)" }
    }
    Update-Task @{ state = 'klaar'; message = $msg; done = $files.Count; current = ''; files = @($out.Values) } -Force
}

# Traktor opent zijn importvenster op het bureaublad; daar dus een kopie. Met een
# eigen achtervoegsel, zodat een eigen bestand met dezelfde naam nooit wordt overschreven.
# "<playlist> (nieuw).nml" komt er ook als "<playlist> (PlaylistFlac).nml" te staan.
function Get-DesktopNml($nml) {
    $desk = [Environment]::GetFolderPath('Desktop')
    if (-not $desk -or -not (Test-Path -LiteralPath $desk)) { return $null }
    $stem = [IO.Path]::GetFileNameWithoutExtension($nml) -replace ' \(nieuw\)$', ''
    return Join-Path $desk ($stem + ' (PlaylistFlac).nml')
}

function Copy-NmlToDesktop($nml) {
    $dest = Get-DesktopNml $nml
    if (-not $dest) { return $null }
    Copy-Item -LiteralPath $nml -Destination $dest -Force
    return $dest
}

function Remove-DesktopNml($nml) {
    $dest = Get-DesktopNml $nml
    if ($dest -and (Test-Path -LiteralPath $dest)) { Remove-Item -LiteralPath $dest -Force }
}
