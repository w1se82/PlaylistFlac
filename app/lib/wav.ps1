# PlaylistFlac - wav.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- AIFF voor oudere CDJ's --------------------------------------------------
#
# Oudere Pioneer-spelers (van voor de CDJ-2000NXS2) spelen geen FLAC. Met de optie
# "AIFF voor oudere CDJ's" zet app\analyse\naar_aiff.py de FLAC's uit een rekordbox.xml
# om naar AIFF (16-bit/44,1 kHz) met tags en cover in <muziekmap>\AIFF (CDJ)\<playlist>,
# en schrijft een tweede xml die naar die AIFF's wijst. Grid en cues blijven gelijk:
# de posities staan in seconden en het omzetten verschuift niets. De FLAC's zelf
# worden alleen gelezen.
#
# Eerst was dit WAV, maar rekordbox leest bij WAV geen cover uit het bestand en bij
# AIFF wel. De interne namen (taaktype 'wav', instelling 'wav', dit bestand) zijn
# gebleven, zodat opgeslagen keuzes blijven werken.
#
# Python: dezelfde omgeving als de analyse (data\analyse\venv). Zonder analyse komen
# daar alleen soundfile, soxr, numpy en mutagen in (ongeveer 40 MB); een latere
# installatie van de analyse bouwt daarop verder.

$WavScript = Join-Path (Join-Path $AppDir 'analyse') 'naar_aiff.py'
$WavXml    = Join-Path $DataDir 'rekordbox (AIFF).xml'

function Get-WavDir { return (Join-Path $MusicDir 'AIFF (CDJ)') }

function Test-WavPython {
    if (-not (Test-Path $AnaPy)) { return $false }
    $r = Invoke-Logged $AnaPy @('-I', $WavScript, '--check') { }
    return -not $r.Code
}

function Install-WavPython {
    if (Test-WavPython) { return }
    $py = Find-Python
    if (-not $py) {
        throw (L 'Voor AIFF is Python nodig. Installeer Python 3 van python.org (op Windows: vink "Add python.exe to PATH" aan) en probeer het daarna opnieuw.' 'AIFF needs Python. Install Python 3 from python.org (on Windows: tick "Add python.exe to PATH") and try again.')
    }
    Add-TaskLog (L 'Eenmalig: soundfile, soxr en mutagen installeren voor het omzetten (ongeveer 40 MB)' 'Once: installing soundfile, soxr and mutagen for the conversion (about 40 MB)')
    New-Item -ItemType Directory -Force $AnaDir | Out-Null
    $pipLog = { param($l) if ($l -match '^(Successfully|ERROR)') { Add-TaskLog $l.Trim() } }
    if (-not (Test-Path $AnaPy)) {
        $r = Invoke-Logged $py.Path @('-m', 'venv', (Join-Path $AnaDir 'venv')) $pipLog
        if ($r.Code) { throw ((L 'Python-omgeving maken mislukte' 'Creating the Python environment failed') + ": $(Last-Lines $r.Err)") }
    }
    $r = Invoke-Logged $AnaPy @('-m', 'pip', 'install', '--disable-pip-version-check', '--progress-bar', 'off', 'soundfile', 'soxr', 'numpy', 'mutagen') $pipLog
    if ($r.Code) { throw ((L 'Installeren mislukte' 'Installing failed') + ": $(Last-Lines $r.Err)") }
    if (-not (Test-WavPython)) { throw (L 'soundfile, soxr of mutagen werkt niet na het installeren.' 'soundfile, soxr or mutagen does not work after installing.') }
}

# Zet de FLAC's in $XmlIn om en schrijft $XmlOut. $Only: alleen playlists in die
# map bovenaan (PlaylistFlac), of leeg voor alle playlists. Geeft de telling terug.
function Convert-RekordboxWav([string]$XmlIn, [string]$XmlOut, [string]$Only) {
    $argList = @('-I', $WavScript, '--xml', $XmlIn, '--uit', $XmlOut, '--map', (Get-WavDir))
    if ($Only) { $argList += @('--alleen', $Only) }
    $st = @{ n = 0; exact = 0; omgezet = 0; bestond = 0; fout = 0; ontbreekt = 0; cover = 0; bytes = 0 }
    $onLine = {
        param($l)
        try { $m = $l | ConvertFrom-Json } catch { return }
        $naam = if ($m.naam) { [IO.Path]::GetFileNameWithoutExtension($m.naam) } else { '' }
        if ($m.t -eq 'start') {
            $st.n = [int]$m.n
            Update-Task @{ phase = 'wav'; total = $st.n; done = 0; current = '' } -Force
            Add-TaskLog ((L '{0} FLAC-bestanden naar AIFF in {1}' '{0} FLAC files to AIFF in {1}') -f $st.n, $m.map)
        } elseif ($m.t -eq 'track') {
            $txt = switch ($m.status) {
                'exact'   { L 'AIFF klaar (bit voor bit gelijk): {0}' 'AIFF done (bit-identical): {0}' }
                'omgezet' { (L 'AIFF klaar ({1} naar 16-bit/44,1 kHz): {0}' 'AIFF done ({1} to 16-bit/44.1 kHz): {0}') }
                default   { L 'AIFF bestond al: {0}' 'AIFF already there: {0}' }
            }
            if ($m.status -ne 'bestond' -and -not $m.cover) { $txt += (L ' (geen cover in de FLAC)' ' (no cover in the FLAC)') }
            Add-TaskLog ($txt -f $naam, $m.uitleg)
            Update-Task @{ done = [int]$m.i; current = $naam } -Force
        } elseif ($m.t -eq 'fout') {
            Add-TaskLog ((L 'Mislukt' 'Failed') + ": $naam - $($m.msg)")
            Update-Task @{ done = [int]$m.i } -Force
        } elseif ($m.t -eq 'klaar') {
            foreach ($k in 'exact', 'omgezet', 'bestond', 'fout', 'ontbreekt', 'cover') { $st[$k] = [int]$m.$k }
            $st.bytes = [double]$m.bytes
        }
    }
    $r = Invoke-Logged $AnaPy $argList $onLine
    if ($r.Code) { throw ((L 'AIFF maken stopte met een fout' 'Making AIFF stopped with an error') + ": $(Last-Lines $r.Err)") }
    return $st
}

function Format-WavResult($st, $xml) {
    $gb = ($st.bytes / 1e9).ToString('0.0', $Inv)
    $gbNl = $gb -replace '\.', ','
    $ok = $st.exact + $st.omgezet + $st.bestond
    $msg = L "$ok van $($st.n) FLAC's staan als AIFF in $(Get-WavDir) ($gbNl GB), $($st.cover) met cover." "$ok of $($st.n) FLACs are in $(Get-WavDir) as AIFF ($gb GB), $($st.cover) with a cover."
    if ($st.fout + $st.ontbreekt) { $msg += L " Bij $($st.fout + $st.ontbreekt) mislukt; die blijven FLAC." " Failed for $($st.fout + $st.ontbreekt); those stay FLAC." }
    $msg += (L ' Kies in rekordbox bij rekordbox xml het bestand ' ' In rekordbox, choose this file at rekordbox xml: ') + $xml + '.'
    return $msg
}

# Wachtrijtaak "wav": Traktor-collectie -> rekordbox.xml, dan de PlaylistFlac-playlists als AIFF.
function Run-RekordboxWav {
    Update-Task @{ name = 'rekordbox'; phase = 'voorbereiden' } -Force
    Add-TaskLog (L 'Traktor-collectie omzetten naar rekordbox.xml' 'Converting the Traktor collection to rekordbox.xml')
    $rb = Export-Rekordbox
    Add-TaskLog ((L '{0} tracks, {1} met beatgrid' '{0} tracks, {1} with a beatgrid') -f $rb.tracks, $rb.grids)
    Install-WavPython
    $st = Convert-RekordboxWav $rb.bestand $WavXml 'PlaylistFlac'
    $msg = Format-WavResult $st $WavXml
    if (-not $st.n) { $msg = L 'In de PlaylistFlac-playlists staan geen FLAC-bestanden, dus er was niets om te zetten.' 'The PlaylistFlac playlists hold no FLAC files, so there was nothing to convert.' }
    Update-Task @{ state = 'klaar'; message = $msg; current = ''; files = @($WavXml) } -Force
}
