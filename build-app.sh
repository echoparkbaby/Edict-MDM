#!/bin/bash
# Builds "BlueConnect Admin.app" — a real double-clickable macOS app bundle
# wrapping the SwiftPM executable. Run from the project root.
#
# Optional signing config: create a gitignored `.env-sign` file in the
# project root with any of: SIGN_ID, BUNDLE_ID, VERSION, BUILD_NUMBER,
# NOTARY_PROFILE, GITHUB_REPO. Without it, the build falls back to ad-hoc
# signing — fine for local-only use, but the app won't be trusted off
# your machine.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load signing config if present
if [[ -f "$PROJECT_ROOT/.env-sign" ]]; then
    set -a; source "$PROJECT_ROOT/.env-sign"; set +a
fi
# Load per-branch app identity AFTER .env-sign so it wins over the secrets
# file's identity defaults. Tracked, differs per branch (MDM on main,
# Admin on release/1.5). Optional: absence falls back to .env-sign/defaults.
if [[ -f "$PROJECT_ROOT/build-identity.sh" ]]; then
    source "$PROJECT_ROOT/build-identity.sh"
fi

# Defaults — override in `.env-sign` or via env to publish under your own
# identity / different version.
APP_NAME="${APP_NAME:-BlueConnect Admin}"
EXEC_NAME="${EXEC_NAME:-BlueConnectAdmin}"
BUNDLE_ID="${BUNDLE_ID:-com.example.BlueConnectAdmin}"
# Default VERSION to whatever the most recent git tag claims — that's
# almost always what a dev build should report. release.sh exports a
# pinned VERSION before invoking us, so its path is unaffected. Falls
# back to 1.0.0 only when there are no tags at all (fresh repo).
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
# .env-sign's BUILD_NUMBER is a starting hint, not a pin. If the env-sign
# value is what we just read (no caller override), bump to a fresh
# timestamp so each dev build reports a unique Info.plist version.
# release.sh sets its own monotonic counter and exports it after sourcing
# .env-sign, so that path still takes precedence.
if [[ -z "${BUILD_NUMBER_EXPLICIT:-}" ]]; then
    BUILD_NUMBER="$(date +%Y%m%d.%H%M%S)"
fi
SIGN_ID="${SIGN_ID:-}"   # empty → ad-hoc signature
APP_BUNDLE="$PROJECT_ROOT/$APP_NAME.app"

cd "$PROJECT_ROOT"
echo "▶ swift build -c release"
swift build -c release
# Build every binary BEFORE touching the old bundle: a failed build must
# leave the previous working .app in place, not a half-built one.
echo "▶ swift build --arch x86_64 (chat universal — already have arm64 from the main build)"
swift build -c release --arch arm64  --product BlueConnectChat
swift build -c release --arch x86_64 --product BlueConnectChat

echo "▶ build .app bundle at: $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$EXEC_NAME" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

# Embed the chat-client binary inside the .app's Resources. The Mac app
# pushes this over SCP on first chat open so the target gets
# /usr/local/bin/blueconnect-chat (a tiny SwiftUI window the GUI Helper
# LaunchAgent launches in the console user's Aqua session).
#
# Universal binary so the app can SCP it to BOTH Apple Silicon and
# Intel fleet Macs. SwiftPM doesn't have a one-shot universal flag —
# build each arch separately then lipo. The pkg path
# (scripts/build-helper-pkg.sh) does the same dual-arch dance for
# the Munki-distributed copy.
CHAT_ARM64="$(swift build -c release --arch arm64  --show-bin-path)/BlueConnectChat"
CHAT_X86_64="$(swift build -c release --arch x86_64 --show-bin-path)/BlueConnectChat"
if [[ -f "$CHAT_ARM64" && -f "$CHAT_X86_64" ]]; then
    lipo -create "$CHAT_ARM64" "$CHAT_X86_64" \
        -output "$APP_BUNDLE/Contents/Resources/blueconnect-chat"
    chmod +x "$APP_BUNDLE/Contents/Resources/blueconnect-chat"
    echo "▶ embedded chat client (universal): $APP_BUNDLE/Contents/Resources/blueconnect-chat ($(du -h "$APP_BUNDLE/Contents/Resources/blueconnect-chat" | cut -f1))"
    echo "  $(lipo -info "$APP_BUNDLE/Contents/Resources/blueconnect-chat")"
else
    echo "⚠️  chat client binary missing — chat feature will be unavailable"
fi

# App icon
if [[ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleExecutable</key>                 <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>                 <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>                <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>                   <string>AppIcon</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>$VERSION</string>
    <key>CFBundleVersion</key>                    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>             <string>15.0</string>
    <key>LSApplicationCategoryType</key>          <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSPrincipalClass</key>                   <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>      <string>BlueConnect Admin uses Apple Events to launch Terminal for SSH/VNC/SCP sessions.</string>
    <key>NSLocalNetworkUsageDescription</key>     <string>BlueConnect Admin discovers SSH and VNC servers on your local network so you can connect to them directly without going through the BlueSky tunnel.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ssh._tcp</string>
        <string>_rfb._tcp</string>
    </array>
    <!-- App Transport Security. The Edict MDM admin APIs (NanoMDM/KMFDDM/
         DEP/devices) and some internal services are reached over plain
         HTTP at fixed private IPs — the tailnet/LAN (WireGuard/Tailscale)
         is the encryption boundary. Rather than disable ATS globally
         (NSAllowsArbitraryLoads), ATS stays ON and plain HTTP is allowed
         only for the specific hosts below. ATS matches per-host, not
         per-port, so one entry covers every port on that host.

         Note: Tailscale's 100.64.0.0/10 (CGNAT) is NOT an RFC1918 private
         range, so NSAllowsLocalNetworking does not cover tailnet hosts —
         they need an explicit entry here. NSExceptionDomains keys are exact
         IPs or hostnames; CIDR ranges are not supported.

         TO ADD A NEW PLAIN-HTTP HOST (e.g. a MunkiReport server on the LAN):
         copy one entry below and replace the <key> with its IP/hostname.
         HTTPS hosts (mdm.example.com, or a self-signed UniFi
         controller handled by the app's trust delegate) need NO entry. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>             <false/>
        <!-- Allows .local and unqualified (dot-less) hostnames + loopback/
             link-local, e.g. a "munkireport.local" or a bare LAN name. -->
        <key>NSAllowsLocalNetworking</key>            <true/>
        <key>NSExceptionDomains</key>
        <dict>
            <!-- MDM stack (NanoMDM 9090 / KMFDDM 9093 / DEP 9001 / devices 9095) -->
            <key>192.0.2.10</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key> <true/>
            </dict>
            <key>192.0.2.11</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key> <true/>
            </dict>
            <!-- bluesky BSC — only needed if you reach the JSON endpoint over
                 http directly instead of the https public URL -->
            <key>192.0.2.20</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key> <true/>
            </dict>
            <key>192.0.2.21</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key> <true/>
            </dict>
            <!-- MunkiReport — inventory dashboard (plain http on the LAN) -->
            <key>192.0.2.30</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key> <true/>
            </dict>
            <!-- Template — to allow another plain-http host, copy a block
                 above and set its IP/hostname:
            <key>10.0.0.NN</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key> <true/>
            </dict>
            -->
        </dict>
    </dict>
</dict>
</plist>
PLIST

if [[ -n "$SIGN_ID" ]]; then
    echo "▶ codesign with: $SIGN_ID"
    # Sign nested Mach-O binaries FIRST with hardened runtime +
    # secure timestamp. The outer `--deep` codesign on the bundle
    # alone doesn't propagate `--options runtime` to nested
    # standalone executables in Resources/ (notarytool rejects
    # them as "binary is not signed with a valid Developer ID
    # certificate" / "no secure timestamp" / "no hardened
    # runtime"). Sign each explicitly, then sign the outer bundle
    # without --deep so we don't re-sign and lose those flags.
    if [[ -f "$APP_BUNDLE/Contents/Resources/blueconnect-chat" ]]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_ID" \
            "$APP_BUNDLE/Contents/Resources/blueconnect-chat"
    fi
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" \
        "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" "$APP_BUNDLE"
else
    echo "▶ codesign ad-hoc (no SIGN_ID set in .env-sign)"
    if [[ -f "$APP_BUNDLE/Contents/Resources/blueconnect-chat" ]]; then
        codesign --force -s - "$APP_BUNDLE/Contents/Resources/blueconnect-chat" >/dev/null 2>&1 || true
    fi
    codesign --force --deep -s - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "▶ verify signature"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

echo "✅ built: $APP_BUNDLE"
echo "   double-click it, or:  open \"$APP_BUNDLE\""
