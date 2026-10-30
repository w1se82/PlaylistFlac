#!/bin/bash
# Dubbelklik om PlaylistFlac te starten (Mac). Zie README.md.
cd "$(dirname "$0")" || exit 1
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/local/microsoft/powershell/7:$PATH"

if ! command -v pwsh >/dev/null 2>&1; then
  echo
  echo "PlaylistFlac heeft PowerShell 7 nodig (gratis, van Microsoft)."
  echo "Installeer het met het .pkg-bestand voor macOS van de pagina die nu opent,"
  echo "of in Terminal met Homebrew:  brew install powershell"
  echo "Dubbelklik daarna opnieuw op Start.command."
  echo
  open "https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos"
  read -r -p "Druk op Enter om dit venster te sluiten."
  exit 1
fi

# Bestanden uit een gedownloade zip krijgen van macOS een quarantaine-vlag.
# Die halen we van de map van PlaylistFlac af, zodat alles gewoon kan starten.
xattr -dr com.apple.quarantine .. 2>/dev/null

pwsh -NoProfile -File ./PlaylistFlac.ps1 "$@"
