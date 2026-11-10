# PlaylistFlac - platform.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- Windows of Mac ---------------------------------------------------------
# (Linux is niet officieel ondersteund, maar handig om te testen.)

function Open-Linux($target) {
    if (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $target } else { Say "Open zelf: $target" Yellow }
}

# Een webadres in de standaardbrowser.
function Open-Url($url) {
    if ($OnWin) { Start-Process $url } elseif ($OnMac) { & open $url } else { Open-Linux $url }
}

# Een map in Verkenner of Finder.
function Open-Folder($dir) {
    if ($OnWin) { Start-Process explorer.exe (Quote-Arg $dir) } elseif ($OnMac) { & open $dir } else { Open-Linux $dir }
}

# Een bestand aanwijzen in Verkenner of Finder.
function Show-File($path) {
    if ($OnWin) { Start-Process explorer.exe "/select,`"$path`"" } elseif ($OnMac) { & open -R $path } else { Open-Linux (Split-Path $path) }
}

# Een tekstbestand openen om te bewerken (Kladblok of TextEdit).
function Open-Editor($path) {
    if ($OnWin) { Start-Process notepad.exe $path } elseif ($OnMac) { & open -e $path } else { Say "Open $path in een teksteditor." Yellow }
}

# Start dit script nog een keer als apart proces, zonder venster.
function Start-Self([string]$ArgText) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path        # powershell.exe of pwsh
    $policy = if ($OnWin) { '-ExecutionPolicy Bypass ' } else { '' }
    $psi.Arguments = "-NoProfile $policy-File " + (Quote-Arg $MainScript) + " $ArgText"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($psi)
}
