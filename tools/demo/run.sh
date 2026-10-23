#!/bin/bash
# Launch an isolated, fake-data copy of Edict MDM for README screenshots.
#   tools/demo/run.sh [workdir]     (default: $TMPDIR/edict-demo)
# Isolation: copies the .app with bundle id xyz.hellocomputer.EdictMDM.demo (own prefs domain +
# keychain service), CFFIXED_USER_HOME redirects Application Support. Real data is never read.
# Screenshot: kill -USR1 <pid>  -> PNGs in $W/shots.   Cleanup: tools/demo/run.sh --clean [workdir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BID=xyz.hellocomputer.EdictMDM.demo
PORT=18765
URL="http://127.0.0.1:$PORT"

if [ "${1:-}" = "--clean" ]; then
  W="${2:-${TMPDIR:-/tmp}/edict-demo}"
  pkill -f "$W/Edict MDM Demo.app/Contents/MacOS/" || true
  pkill -f "mock_server.py $PORT" || true
  defaults delete "$BID" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$BID.plist"
  for a in "$URL/bluesky|admin" EdictMDM.nanoMDMAPIKey EdictMDM.kmfddmAPIKey EdictMDM.scepChallenge BlueConnectAdmin.munkiReportAPIToken; do
    security delete-generic-password -s "$BID" -a "$a" >/dev/null 2>&1 || true
  done
  exit 0
fi

W="${1:-${TMPDIR:-/tmp}/edict-demo}"
APP="$W/Edict MDM Demo.app"
mkdir -p "$W/home/Library/Application Support/EdictMDM" "$W/shots"

rm -rf "$APP"
cp -R "$REPO/Edict MDM.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" 2>/dev/null
clang -dynamiclib -fobjc-arc -framework AppKit -framework Security "$HERE/demo_inject.m" -o "$W/demo_inject.dylib"
codesign --force -s - "$W/demo_inject.dylib"

python3 -I "$HERE/mock_server.py" --seed-library "$W/home/Library/Application Support/EdictMDM/ddm-library.json"

d() { defaults write "$BID" "$@"; }
defaults delete "$BID" 2>/dev/null || true
d didImportFromBlueConnectAdmin -bool YES
d keychainThisDeviceOnlyMigrated.v1 -bool YES
d apiURL "$URL/bluesky"; d apiUsername admin; d hasSavedLogin -bool YES; d requireTouchID -bool NO
d serverFqdn bluesky.northwind.example; d defaultRemoteUser nwadmin
d localNetworkEnabled -bool NO; d tailscaleEnabled -bool NO
d mdmEnabled -bool YES
d nanoMDMBaseURL "$URL/nanomdm"; d kmfddmBaseURL "$URL/kmfddm"; d mdmDevicesAPIBaseURL "$URL/enroll"
d mdmPublicURL https://mdm.northwind.example
d mdmEnrollmentProfileID com.northwind.mdm.enroll
d mdmProfileDisplayName "Northwind Studio MDM"; d mdmProfileOrganization "Northwind Studio"
d mdmProfileDescription "Enrolls this Mac in Northwind Studio device management."
d mdmProfileConsentText "Northwind IT can install apps and settings and see device inventory. It cannot see your files, mail, or browsing."
d mdmRequireFileVault -bool YES; d mdmMinOSVersion 15.0
d mdmOnboardingEnabled -bool YES; d mdmOnboardSetsRaw -string '["baseline"]'
d munkiReportURL "$URL/munkireport"
d mdmSmartGroupsRaw -string '[{"id":"0B9C1C34-1111-4E3A-9C61-1F0A00000001","name":"Design team","rules":[{"id":"0B9C1C34-1111-4E3A-9C61-1F0A00000011","field":"Model contains","value":"MacBook Pro"}],"onboardProfileIDs":[],"onboardSets":["design"]},{"id":"0B9C1C34-1111-4E3A-9C61-1F0A00000002","name":"Needs attention","rules":[{"id":"0B9C1C34-1111-4E3A-9C61-1F0A00000012","field":"Out of compliance","value":""}],"onboardProfileIDs":[],"onboardSets":[]}]'
d unlockedWindowFrame -string "{{20, 60}, {1400, 850}}"
d sidebarFilter "${EDICT_DEMO_VIEW:-all}"
d scanSubnets 192.0.2.0/24
d mdmDevicesRaw -string "[{\"id\":\"6FBF079A-AA7D-50AE-8573-0225F30589F2\",\"label\":\"Leo's MacBook Pro\"}]"
d hostsTableColumnsJSON -string '{"columnOrder":[{"base":{"explicit":{"_0":"favorite"}}},{"base":{"explicit":{"_0":"active"}}},{"base":{"explicit":{"_0":"hostname"}}},{"base":{"explicit":{"_0":"mdm"}}},{"base":{"explicit":{"_0":"mdm_os"}}},{"base":{"explicit":{"_0":"mdm_filevault"}}},{"base":{"explicit":{"_0":"mdm_user"}}},{"base":{"explicit":{"_0":"status"}}},{"base":{"explicit":{"_0":"last_seen"}}},{"base":{"explicit":{"_0":"connect"}}},{"base":{"explicit":{"_0":"id"}}},{"base":{"explicit":{"_0":"user"}}},{"base":{"explicit":{"_0":"recent"}}}],"perColumnState":[{"base":{"explicit":{"_0":"favorite"}}},{"visibility":{"automatic":{}},"currentWidth":28},{"base":{"explicit":{"_0":"active"}}},{"visibility":{"automatic":{}},"currentWidth":30},{"base":{"explicit":{"_0":"hostname"}}},{"visibility":{"automatic":{}},"currentWidth":190},{"base":{"explicit":{"_0":"mdm"}}},{"visibility":{"automatic":{}},"currentWidth":70},{"base":{"explicit":{"_0":"mdm_os"}}},{"visibility":{"automatic":{}},"currentWidth":80},{"base":{"explicit":{"_0":"mdm_filevault"}}},{"visibility":{"automatic":{}},"currentWidth":80},{"base":{"explicit":{"_0":"mdm_user"}}},{"visibility":{"automatic":{}},"currentWidth":160},{"base":{"explicit":{"_0":"status"}}},{"visibility":{"automatic":{}},"currentWidth":170},{"base":{"explicit":{"_0":"last_seen"}}},{"visibility":{"automatic":{}},"currentWidth":180},{"base":{"explicit":{"_0":"connect"}}},{"visibility":{"automatic":{}},"currentWidth":210},{"base":{"explicit":{"_0":"id"}}},{"visibility":{"hidden":{}},"currentWidth":34},{"base":{"explicit":{"_0":"user"}}},{"visibility":{"hidden":{}},"currentWidth":130},{"base":{"explicit":{"_0":"recent"}}},{"visibility":{"hidden":{}},"currentWidth":130}]}'
d connectPanelVisible -bool "${EDICT_DEMO_INSPECTOR:-YES}"

pkill -f "mock_server.py $PORT" || true
nohup python3 -I "$HERE/mock_server.py" $PORT >"$W/mock.log" 2>&1 &
sleep 0.5
EDICT_DEMO_API="$URL/bluesky" EDICT_DEMO_SHOTS="$W/shots" EDICT_DEMO_CMD="$W/cmd.txt" CFFIXED_USER_HOME="$W/home" \
  DYLD_INSERT_LIBRARIES="$W/demo_inject.dylib" \
  "$APP/Contents/MacOS/BlueConnectAdmin" >"$W/app.log" 2>&1 &   # no nohup: SIP strips DYLD_* when exec-ing system binaries
PID=$!
echo $PID > "$W/pid"
sleep 6   # let it load, then size the window (capped by the screen's visible frame)
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set position of window 1 to {20, 40}" -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set size of window 1 to {1400, 850}" || true
echo "demo pid $PID  (screenshot: kill -USR1 $PID -> $W/shots; logs: $W/mock.log $W/app.log)"
