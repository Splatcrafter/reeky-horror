#!/usr/bin/env bash
# Runs once after the container is created, as user dev.
set -euo pipefail

firewall-wait 120

cd /workspace

# The Windows bind mount isn't owned by "dev" -> git would complain otherwise.
git config --global --add safe.directory /workspace
git config --global core.autocrlf input

# Install the Luau/Roblox toolchain from rokit.toml (rojo, stylua, selene, ...)
if [[ -f rokit.toml ]]; then
  echo "🧰 Installing tools from rokit.toml ..."
  rokit install --no-trust-check
else
  echo "ℹ️  No rokit.toml found – skipping tool installation."
fi

echo
echo "✅ Dev container ready."
echo "   🤖 claude          – start Claude Code"
echo "   🔄 rojo serve      – live sync to Roblox Studio (port 34872)"
echo "   🛡️  firewall-check  – check the firewall"
