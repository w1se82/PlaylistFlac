# PlaylistFlac - koppeling.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# De link playlistflac:// laat index.html (los geopend) de tool starten.
# Windows: alleen voor deze gebruiker (HKCU), geen adminrechten nodig.
# Mac: een klein app'je PlaylistFlac.app in de map van PlaylistFlac (gemaakt met
# osacompile, dat bij macOS hoort) dat playlistflac:// afhandelt; dubbelklikken
# start de tool ook.
# Linux: playlistflac.desktop in ~/.local/share/applications (ook in het
# appmenu), als standaard voor x-scheme-handler/playlistflac via xdg-mime.
$ProtocolKey = 'HKCU:\Software\Classes\playlistflac'
$MacApp = Join-Path $Root 'PlaylistFlac.app'

function Register-Protocol {
    if ($OnMac) { Register-MacApp; return }
    if (-not $OnWin) { Register-LinuxApp; return }
    $cmd ='powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "{0}" -Link' -f $MainScript
    $cmdKey = "$ProtocolKey\shell\open\command"
    if ((Test-Path $cmdKey) -and (Get-Item $cmdKey).GetValue('') -eq $cmd) { return }
    New-Item -Path $cmdKey -Force | Out-Null
    Set-Item -Path $ProtocolKey -Value 'URL:PlaylistFlac'
    New-ItemProperty -Path $ProtocolKey -Name 'URL Protocol' -Value '' -Force | Out-Null
    Set-Item -Path $cmdKey -Value $cmd
}

$LsRegister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

# Mac: PlaylistFlac.app maken (of opnieuw, als de map of PowerShell verplaatst is).
# Het app'je start dit script op de achtergrond; via playlistflac:// met -Link.
function Register-MacApp {
    $pwsh = (Get-Process -Id $PID).Path
    $sig = "$pwsh|$MainScript|$Version"
    $flag = Join-Path $StatusDir 'mac-app.txt'
    if ((Test-Path -LiteralPath $MacApp) -and (Test-Path $flag) -and [IO.File]::ReadAllText($flag, $Utf8).Trim() -eq $sig) { return }
    $sh = { param($s) "'" + ($s -replace "'", "'\''") + "'" }                  # voor de shell
    $as = { param($s) '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }  # voor AppleScript
    # een app die vanuit Finder start, kent /opt/homebrew/bin en /usr/local/bin niet
    $cmd = 'export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; nohup ' + (& $sh $pwsh) + ' -NoProfile -File ' + (& $sh $MainScript)
    $src = @(
        'on run'
        '    do shell script ' + (& $as "$cmd >/dev/null 2>&1 &")
        'end run'
        'on open location theURL'
        '    do shell script ' + (& $as "$cmd -Link >/dev/null 2>&1 &")
        'end open location'
    ) -join "`n"
    $tmp = Join-Path $StatusDir 'PlaylistFlac.applescript'
    [IO.File]::WriteAllText($tmp, $src, $Utf8)
    if (Test-Path -LiteralPath $MacApp) { Remove-Item -LiteralPath $MacApp -Recurse -Force }
    & osacompile -o $MacApp $tmp
    if ($LASTEXITCODE) { throw 'osacompile maakte PlaylistFlac.app niet.' }
    $plist = Join-Path $MacApp 'Contents/Info.plist'
    $pb = '/usr/libexec/PlistBuddy'
    & $pb -c 'Delete :CFBundleURLTypes' $plist 2>$null
    & $pb -c 'Add :CFBundleURLTypes array' -c 'Add :CFBundleURLTypes:0 dict' -c 'Add :CFBundleURLTypes:0:CFBundleURLName string PlaylistFlac' `
          -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes array' -c 'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string playlistflac' $plist
    & $pb -c 'Set :CFBundleIdentifier local.playlistflac' $plist 2>$null
    # Info.plist aangepast: opnieuw (ad-hoc) ondertekenen, anders weigert macOS het app'je
    & codesign --force --deep --sign - $MacApp 2>$null
    if (Test-Path $LsRegister) { & $LsRegister -f $MacApp }
    Remove-Item $tmp -Force
    [IO.File]::WriteAllText($flag, $sig, $Utf8)
}

# Linux: ~/.local/share/applications/playlistflac.desktop, dat Start.sh start;
# via playlistflac:// krijgt Start.sh de link mee en maakt er -Link van.
function Get-LinuxAppDir {
    $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path (Join-Path $HOME '.local') 'share' }
    return Join-Path $base 'applications'
}

function Register-LinuxApp {
    $starter = Join-Path $AppDir 'Start.sh'
    if (-not (Test-Path -LiteralPath $starter)) { return }
    $sig = "$starter|$Version"
    $flag = Join-Path $StatusDir 'linux-app.txt'
    $dir = Get-LinuxAppDir
    $file = Join-Path $dir 'playlistflac.desktop'
    if ((Test-Path -LiteralPath $file) -and (Test-Path $flag) -and [IO.File]::ReadAllText($flag, $Utf8).Trim() -eq $sig) { return }
    & chmod +x $starter
    # Exec: tussen dubbele aanhalingstekens, met \ voor " ` $ \; daarna nog een
    # keer elke \ verdubbelen (escape voor het .desktop-bestand) en %% voor %
    $q = $starter -replace '(["`$\\])', '\$1'
    $q = $q -replace '\\', '\\' -replace '%', '%%'
    $exec = '"' + $q + '" %u'
    $text = @(
        '[Desktop Entry]'
        'Type=Application'
        'Name=PlaylistFlac'
        'Comment=Spotify-playlists als FLAC via Soulseek'
        "Exec=$exec"
        'Icon=audio-x-generic'
        'Terminal=false'
        'Categories=AudioVideo;Audio;'
        'MimeType=x-scheme-handler/playlistflac;'
    ) -join "`n"
    New-Item -ItemType Directory -Force $dir | Out-Null
    [IO.File]::WriteAllText($file, "$text`n", $Utf8)
    if (Get-Command xdg-mime -ErrorAction SilentlyContinue) { & xdg-mime default playlistflac.desktop x-scheme-handler/playlistflac }
    if (Get-Command update-desktop-database -ErrorAction SilentlyContinue) { & update-desktop-database $dir 2>$null }
    [IO.File]::WriteAllText($flag, $sig, $Utf8)
}

# Eenmalig een snelkoppeling 'PlaylistFlac' op het bureaublad: op Windows naar
# index.html, op een Mac naar PlaylistFlac.app. Gooi je die weg, dan komt hij
# niet terug (het vlaggetje in data\status blijft).
function Add-DesktopShortcut {
    $flag = Join-Path $StatusDir 'snelkoppeling.txt'
    if (Test-Path $flag) { return }
    if ($OnMac) {
        $lnk = Join-Path (Join-Path $HOME 'Desktop') 'PlaylistFlac.app'
        if ((Test-Path -LiteralPath $MacApp) -and -not (Test-Path -LiteralPath $lnk)) {
            New-Item -ItemType SymbolicLink -Path $lnk -Target $MacApp | Out-Null
            Say "Snelkoppeling 'PlaylistFlac' op je bureaublad gezet." Green
        }
        [IO.File]::WriteAllText($flag, "$lnk`n$((Get-Date).ToString('o'))`n", $Utf8)
        return
    }
    if (-not $OnWin) { return }
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desk 'PlaylistFlac.lnk'
    if ($desk -and -not (Test-Path -LiteralPath $lnk)) {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = $UiFile
        $sc.WorkingDirectory = $Root
        $sc.Description = 'PlaylistFlac: Spotify-playlists als FLAC via Soulseek'
        $sc.Save()
        Say "Snelkoppeling 'PlaylistFlac' op je bureaublad gezet." Green
    }
    [IO.File]::WriteAllText($flag, "$lnk`r`n$((Get-Date).ToString('o'))`r`n", $Utf8)
}

function Unregister-Protocol {
    if ($OnMac) {
        if (Test-Path -LiteralPath $MacApp) {
            if (Test-Path $LsRegister) { & $LsRegister -u $MacApp }
            Remove-Item -LiteralPath $MacApp -Recurse -Force
        }
        $flag = Join-Path $StatusDir 'mac-app.txt'
        if (Test-Path $flag) { Remove-Item $flag -Force }
        return
    }
    if (-not $OnWin) {
        $file = Join-Path (Get-LinuxAppDir) 'playlistflac.desktop'
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        if (Get-Command update-desktop-database -ErrorAction SilentlyContinue) { & update-desktop-database (Get-LinuxAppDir) 2>$null }
        $flag = Join-Path $StatusDir 'linux-app.txt'
        if (Test-Path $flag) { Remove-Item $flag -Force }
        return
    }
    if (Test-Path $ProtocolKey) { Remove-Item $ProtocolKey -Recurse -Force }
}
