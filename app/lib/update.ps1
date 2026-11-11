# PlaylistFlac - update.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- bijwerken vanaf GitHub -------------------------------------------------

# Vergelijkt versies als 1.3.4-beta: <0 als $a ouder is dan $b, 0 als gelijk, >0 als nieuwer.
function Compare-AppVersion([string]$a, [string]$b) {
    $parse = {
        param($v)
        if ($v -notmatch '^v?(\d+(?:\.\d+)+)(-.+)?$') { throw "Onbekend versienummer: $v" }
        return @{ Nr = [version]$Matches[1]; Extra = "$($Matches[2])" }
    }
    $x = & $parse $a; $y = & $parse $b
    if ($x.Nr -ne $y.Nr) { return $x.Nr.CompareTo($y.Nr) }
    if ($x.Extra -eq $y.Extra) { return 0 }
    if (-not $x.Extra) { return 1 }       # 1.4.0 is nieuwer dan 1.4.0-beta
    if (-not $y.Extra) { return -1 }
    return [string]::CompareOrdinal($x.Extra, $y.Extra)
}

# De nieuwste uitgave op GitHub, ook als die beta is (/releases/latest slaat die over).
function Get-LatestRelease {
    $list = Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 "https://api.github.com/repos/$UpdateRepo/releases?per_page=20"
    $best = $null
    foreach ($r in $list) {
        if ($r.draft -or $r.tag_name -notmatch '^v?\d+(\.\d+)+(-.+)?$') { continue }
        $asset = @($r.assets | Where-Object { $_.name -match '^PlaylistFlac-.+\.zip$' }) | Select-Object -First 1
        if (-not $asset) { continue }
        $v = $r.tag_name -replace '^v', ''
        if (-not $best -or (Compare-AppVersion $v $best.Version) -gt 0) { $best = @{ Version = $v; Url = $asset.browser_download_url } }
    }
    return $best
}

function Get-UpdateInfo {
    $latest = Get-LatestRelease
    if (-not $latest) { return @{ current = $Version; latest = $null; newer = $false } }
    return @{ current = $Version; latest = $latest.Version; newer = ((Compare-AppVersion $latest.Version $Version) -gt 0) }
}

# Zet een uitgepakte versie over de huidige heen. data\ en app\bin zitten niet in de
# zip en blijven dus staan. Lukt het kopieren niet, dan gaat alles terug.
function Install-UpdateFiles($new, $work) {
    $rels = @(Get-ChildItem -LiteralPath $new -Recurse -File | ForEach-Object { $_.FullName.Substring($new.TrimEnd('\', '/').Length + 1) })
    foreach ($rel in $rels) {
        if ($rel -match '^(data|app[\\/]bin)([\\/]|$)') { throw "De update bevat een bestand dat er niet in hoort: $rel" }
    }
    $backup = Join-Path $work 'oud'
    $added = New-Object Collections.ArrayList
    foreach ($rel in $rels) {
        $cur = Join-Path $Root $rel
        if (Test-Path -LiteralPath $cur) {
            $bak = Join-Path $backup $rel
            New-Item -ItemType Directory -Force (Split-Path $bak) | Out-Null
            Copy-Item -LiteralPath $cur -Destination $bak -Force
        } else { [void]$added.Add($cur) }
    }
    try {
        foreach ($rel in $rels) {
            $dest = Join-Path $Root $rel
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            Copy-Item -LiteralPath (Join-Path $new $rel) -Destination $dest -Force
        }
    } catch {
        foreach ($rel in $rels) {
            $bak = Join-Path $backup $rel
            if (Test-Path -LiteralPath $bak) { Copy-Item -LiteralPath $bak -Destination (Join-Path $Root $rel) -Force }
        }
        foreach ($f in $added) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        throw "Bijwerken mislukt, de oude versie is teruggezet: $($_.Exception.Message)"
    }
}

function Install-Update {
    if (Task-Running) { throw 'Er loopt nog een taak. Bijwerken kan zodra die klaar is.' }
    $latest = Get-LatestRelease
    if (-not $latest -or (Compare-AppVersion $latest.Version $Version) -le 0) { throw 'Je hebt de nieuwste versie al.' }
    $work = Join-Path $StatusDir 'update'
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    $zip = Join-Path $work 'update.zip'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 $latest.Url -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'nieuw') -Force
    $new = Join-Path (Join-Path $work 'nieuw') 'PlaylistFlac'
    # eerst controleren of dit echt een werkende versie is; pas dan iets vervangen
    $script = Join-Path (Join-Path $new 'app') 'PlaylistFlac.ps1'
    foreach ($need in (Join-Path $new 'index.html'), $script, (Join-Path (Join-Path (Join-Path $new 'app') 'analyse') 'analyse.py')) {
        if (-not (Test-Path -LiteralPath $need)) { throw 'De download is niet compleet. Er is niets veranderd.' }
    }
    if (-not (Select-String -LiteralPath $script -SimpleMatch "'$($latest.Version)'" -Quiet)) { throw 'De download hoort niet bij deze versie. Er is niets veranderd.' }
    # vanaf 1.4.0 staat het script in stukken in app\lib en de interface deels in ui\
    $libNew = Join-Path (Join-Path $new 'app') 'lib'
    if ((Select-String -LiteralPath $script -SimpleMatch '$LibParts' -Quiet) -and
        -not ((Test-Path -LiteralPath $libNew) -and (Test-Path -LiteralPath (Join-Path (Join-Path $new 'ui') 'app.js')))) {
        throw 'De download is niet compleet. Er is niets veranderd.'
    }
    $scripts = @($script) + @(if (Test-Path -LiteralPath $libNew) { Get-ChildItem -LiteralPath $libNew -Filter '*.ps1' | ForEach-Object { $_.FullName } })
    foreach ($s in $scripts) {
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($s, [ref]$null, [ref]$errs)
        if ($errs) { throw 'De download bevat een fout. Er is niets veranderd.' }
    }
    Install-UpdateFiles $new $work
    if (-not $OnWin) {
        foreach ($s in 'Start.command', 'Start.sh') {
            $f = Join-Path $AppDir $s
            if (Test-Path -LiteralPath $f) { & chmod +x $f }
        }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    return $latest.Version
}
