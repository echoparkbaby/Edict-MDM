#!/bin/bash
# Launch the demo and capture every README screenshot into docs/screenshots/edict/.
#   tools/demo/capture.sh [workdir]
# Drives the UI through the Accessibility API (the terminal needs Accessibility permission).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../docs/screenshots/edict"
W="${1:-${TMPDIR:-/tmp}/edict-demo}"
mkdir -p "$OUT" "$W"
swiftc -O "$HERE/ax.swift" -o "$W/ax" 2>/dev/null
"$HERE/run.sh" --clean "$W"
EDICT_DEMO_VIEW=mdm:enroll EDICT_DEMO_INSPECTOR=NO "$HERE/run.sh" "$W"
PID=$(cat "$W/pid")
ax() { "$W/ax" "$PID" "$@" >/dev/null; }
path() { "$W/ax" "$PID" dump | grep -E "$1" | head -1 | awk '{print $1}'; }
shot() {  # in-app capture via the injected dylib (SIGUSR1); composite includes sheets
  rm -f "$W/shots/"*.png; kill -USR1 "$PID"; sleep 1.5
  f=$(ls "$W/shots/"composite-*.png 2>/dev/null | head -1 || true); [ -z "$f" ] && f=$(ls -S "$W/shots/"win-*.png | head -1)
  mv "$f" "$OUT/$1.png"; echo "saved $1.png"
}
sleep 2; shot enrollment
ax find "Declarations"; sleep 2
ax sel "$("$W/ax" "$PID" dump | grep -B3 'AXStaticText Enforce macOS update' | grep AXRow | awk '{print $1}')"; sleep 1.5; shot declarations
ax find "Add Declaration"; sleep 2; shot declaration-templates
ax find "Cancel"; sleep 1
ax act "$(path 'AXRadioButton Sets')" AXPress; sleep 1.5; shot ddm-sets
ax find "Dashboard"; sleep 6; ax find "Summary"; sleep 1.5; shot dashboard
ax find "All Hosts"; sleep 2; shot fleet
ax find "Expand pane | chevron.left"; sleep 1
ax sel "$(path 'AXOutline')".1; sleep 1.5
ax act "$(path 'AXRadioButton MDM')" AXPress; sleep 2
ax act "$(path 'AXButton Load')" AXPress; sleep 1.5
ax act "$("$W/ax" "$PID" dump | grep 'AXButton Security' | tail -1 | awk '{print $1}')" AXPress; sleep 4; shot device-detail
ax act "$(path 'AXRadioButton MunkiReport')" AXPress; sleep 2; shot device-munkireport
"$HERE/run.sh" --clean "$W"
