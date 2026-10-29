#!/usr/bin/env bash
# Läuft einmalig nach dem Erstellen des Containers als User dev.
set -euo pipefail

firewall-wait 120

cd /workspace

# Bind-Mount von Windows gehört nicht "dev" -> Git würde sonst meckern.
git config --global --add safe.directory /workspace
git config --global core.autocrlf input

# Luau-/Roblox-Toolchain aus rokit.toml installieren (rojo, stylua, selene, …)
if [[ -f rokit.toml ]]; then
  echo "🧰 Installiere Tools aus rokit.toml …"
  rokit install --no-trust-check
else
  echo "ℹ️  Keine rokit.toml gefunden – überspringe Tool-Installation."
fi

echo
echo "✅ Dev-Container bereit."
echo "   🤖 claude          – Claude Code starten"
echo "   🔄 rojo serve      – Live-Sync zu Roblox Studio (Port 34872)"
echo "   🛡️  firewall-check  – Firewall prüfen"
