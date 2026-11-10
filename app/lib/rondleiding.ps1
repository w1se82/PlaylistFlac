# PlaylistFlac - rondleiding.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- rondleiding -------------------------------------------------------------
# De interface legt onderdelen uit op het moment dat je ze voor het eerst ziet
# (ui\rondleiding.js). Welke uitleg je al gezien hebt staat hier, en niet in de
# browser: de poort kan per keer verschillen, en daarmee de opslag van de browser.

$RondleidingPath = Join-Path $StatusDir 'rondleiding.json'

function Read-Rondleiding {
    $r = [ordered]@{ seen = @(); off = $false }
    if (-not (Test-Path -LiteralPath $RondleidingPath)) { return $r }
    try {
        $j = [IO.File]::ReadAllText($RondleidingPath, $Utf8) | ConvertFrom-Json
        $r.seen = @($j.seen | Where-Object { $_ } | ForEach-Object { "$_" })
        $r.off = [bool]$j.off
    } catch { }
    return $r
}

function Update-Rondleiding($b) {
    $r = Read-Rondleiding
    if ($b.reset) {
        $r.seen = @(); $r.off = $false
    } else {
        if ($b.off) { $r.off = $true }
        $id = "$($b.seen)"
        # alleen korte namen zoals 'kies-versie'; dit komt van de pagina
        if ($id -match '^[a-z0-9-]{1,40}$' -and $r.seen -notcontains $id) { $r.seen = @($r.seen) + $id }
    }
    New-Item -ItemType Directory -Force $StatusDir | Out-Null
    [IO.File]::WriteAllText($RondleidingPath, ($r | ConvertTo-Json -Compress), $Utf8)
    return $r
}
