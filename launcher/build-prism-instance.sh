#!/usr/bin/env bash
# Builds a Prism Launcher instance zip that friends import with one URL.
# Minecraft/Fabric versions are read from pack/pack.toml, so the zip always matches the pack.
# On every launch the instance runs packwiz-installer-bootstrap, which syncs mods from PACK_URL.
#
# Usage: launcher/build-prism-instance.sh <output.zip>
set -euo pipefail

PACK_URL="https://samueldpackard.github.io/friends-smp/pack.toml"
BOOTSTRAP_URL="https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar"
NAME="Friends SMP"

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mc=$(sed -n 's/^minecraft = "\(.*\)"/\1/p' "$repo/pack/pack.toml")
fabric=$(sed -n 's/^fabric = "\(.*\)"/\1/p' "$repo/pack/pack.toml")
[[ -n "$mc" && -n "$fabric" ]] || { echo "could not read versions from pack.toml" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.minecraft"

cat > "$work/mmc-pack.json" <<EOF
{
    "components": [
        { "uid": "net.minecraft", "version": "$mc", "important": true },
        { "uid": "net.fabricmc.intermediary", "version": "$mc", "dependencyOnly": true },
        { "uid": "net.fabricmc.fabric-loader", "version": "$fabric" }
    ],
    "formatVersion": 1
}
EOF

# QSettings ini: inner quotes are escaped so paths with spaces (macOS "Application Support") work.
cat > "$work/instance.cfg" <<EOF
[General]
ConfigVersion=1.2
InstanceType=OneSix
name=$NAME
iconKey=grass
OverrideMemory=true
MinMemAlloc=512
MaxMemAlloc=4096
OverrideCommands=true
PreLaunchCommand="\"\$INST_JAVA\" -jar packwiz-installer-bootstrap.jar $PACK_URL"
EOF

curl -fsSL "$BOOTSTRAP_URL" -o "$work/.minecraft/packwiz-installer-bootstrap.jar"

rm -f "$out"
(cd "$work" && zip -qr "$out" instance.cfg mmc-pack.json .minecraft)
echo "Built $out (Minecraft $mc, Fabric $fabric)"
