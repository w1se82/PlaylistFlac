# PlaylistFlac - release.ps1, ingeladen door PlaylistFlac.ps1 (dot-source).
# Puur ASCII houden: Windows PowerShell 5.1 leest bestanden zonder BOM als ANSI.

# --- inpakken -------------------------------------------------------------

# Zip met Unix-rechten erin, zodat Start.command op een Mac na het uitpakken
# uitvoerbaar is (Compress-Archive kan dat niet). Alles onder $stage gaat mee.
function Write-ReleaseZip($stage, $zip) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $toInt = { param([uint32]$u) [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0) }
    $exec = & $toInt (0x81ED * 65536)      # gewoon bestand, rwxr-xr-x (0100755)
    $plain = & $toInt (0x81A4 * 65536)     # gewoon bestand, rw-r--r-- (0100644)
    $fs = [IO.File]::Open($zip, 'CreateNew')
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $rel = $f.FullName.Substring($stage.TrimEnd('\').Length + 1) -replace '\\', '/'
            $e = $za.CreateEntry($rel, [IO.Compression.CompressionLevel]::Optimal)
            $e.LastWriteTime = $f.LastWriteTime
            $e.ExternalAttributes = $(if ($f.Extension -eq '.command') { $exec } else { $plain })
            $out = $e.Open(); $in = [IO.File]::OpenRead($f.FullName)
            try { $in.CopyTo($out) } finally { $in.Dispose(); $out.Dispose() }
        }
    } finally { $za.Dispose(); $fs.Dispose() }
    # .NET schrijft "gemaakt op MS-DOS"; dan negeert macOS de rechten. Op Unix zetten.
    $b = [IO.File]::ReadAllBytes($zip)
    $eocd = -1
    for ($i = $b.Length - 22; $i -ge 0; $i--) { if ([BitConverter]::ToUInt32($b, $i) -eq 0x06054b50) { $eocd = $i; break } }
    if ($eocd -lt 0) { throw 'Zip zonder einde?' }
    $n = [BitConverter]::ToUInt16($b, $eocd + 10)
    $pos = [int][BitConverter]::ToUInt32($b, $eocd + 16)
    for ($k = 0; $k -lt $n; $k++) {
        if ([BitConverter]::ToUInt32($b, $pos) -ne 0x02014b50) { throw 'Onverwachte zip-indeling.' }
        $b[$pos + 5] = 3
        $pos += 46 + [BitConverter]::ToUInt16($b, $pos + 28) + [BitConverter]::ToUInt16($b, $pos + 30) + [BitConverter]::ToUInt16($b, $pos + 32)
    }
    [IO.File]::WriteAllBytes($zip, $b)
}
