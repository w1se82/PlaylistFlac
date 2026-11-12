# PlaylistFlac - taal.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- taal --------------------------------------------------------------------
# Meldingen in het Nederlands of het Engels: L 'Nederlands' 'English'.
# $script:Lang zet de webinterface per verzoek (Resolve-Lang: de instelling
# "taal", anders de taal van je browser); een taak krijgt hem via de opdracht,
# de Spotify-login via -Taal. Zonder dat alles: de taal van de computer.
# De interface zelf vertaalt in de browser (ui\i18n.js, ui\lang-en.js).

function Get-OsLang {
    if ($script:OsLang) { return $script:OsLang }
    $name = ''
    try {
        if ($OnMac) { $name = "$(& defaults read -g AppleLocale 2>$null)" }
        if (-not $name) { $name = (Get-UICulture).Name }
        if (-not $name) { $name = "$env:LANG" }
    } catch { }
    $script:OsLang = if ($name -match '^nl') { 'nl' } else { 'en' }
    return $script:OsLang
}

function L([string]$nl, [string]$en) { if ($script:Lang -eq 'en') { return $en } return $nl }

# De taal voor een verzoek van de interface: de instelling "taal", anders de
# eerste taal van de browser (Accept-Language), anders die van de computer.
function Resolve-Lang($req) {
    $set = "$($cfg['taal'])".ToLower()
    if ($set -in 'nl', 'en') { return $set }
    $al = "$($req.Headers['Accept-Language'])".Trim()
    if ($al) { if ($al -match '^nl') { return 'nl' } else { return 'en' } }
    return Get-OsLang
}
