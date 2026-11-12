#!/bin/bash
# Start PlaylistFlac op Linux: ./Start.sh (of dubbelklik, als je bestandsbeheer
# scripts mag uitvoeren). Zie README.md.
# De playlistflac://-koppeling (index.html) start dit script met de link als
# eerste argument; dat wordt -Link.
cd "$(dirname "$(readlink -f "$0")")" || exit 1

if ! command -v pwsh >/dev/null 2>&1; then
  echo
  # Nederlands of Engels, net als de rest: volgens de taal van de computer
  if [[ "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" == nl* ]]; then
    echo "PlaylistFlac heeft PowerShell 7 (pwsh) nodig, gratis van Microsoft."
    echo "Debian, Ubuntu, Kali:  sudo apt install powershell"
    echo "Anders: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
    close="Druk op Enter om dit venster te sluiten."
  else
    echo "PlaylistFlac needs PowerShell 7 (pwsh), free from Microsoft."
    echo "Debian, Ubuntu, Kali:  sudo apt install powershell"
    echo "Otherwise: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
    close="Press Enter to close this window."
  fi
  echo
  [ -t 0 ] && read -r -p "$close"
  exit 1
fi

if [[ "$1" == playlistflac:* ]]; then
  shift
  set -- -Link "$@"
fi

exec pwsh -NoProfile -File ./PlaylistFlac.ps1 "$@"
