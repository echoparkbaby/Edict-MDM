#!/bin/bash
# Per-branch app identity — sourced by build-app.sh, make-dmg.sh, and
# release.sh AFTER .env-sign so it OVERRIDES the secrets file's identity.
#
# This file is TRACKED and differs per branch, which is the whole point:
#   - main          → "Edict MDM"          (v2, private, Forgejo-only)
#   - release/1.5    → "BlueConnect Admin" (v1.5 maintenance, public)
#
# Identity is public (bundle ID, app name) so it belongs in version
# control. Secrets (SIGN_ID, NOTARY_PROFILE, tokens) stay in the gitignored
# .env-sign. Assignment is unconditional (not `:=`) on purpose: .env-sign
# sets BUNDLE_ID, so assign-if-unset would NOT win. This file is the
# authority for identity; to do a one-off override, edit here.
#
# THIS COPY IS THE v2 / main IDENTITY.

APP_NAME="Edict MDM"
BUNDLE_ID="xyz.hellocomputer.EdictMDM"
DMG_NAME="Edict-MDM.dmg"
# EXEC_NAME stays BlueConnectAdmin — it's the SwiftPM product (binary)
# name inside the bundle, not user-visible, and renaming it would churn
# Package.swift for no gain.

# Release publish targets. v2 is private: Forgejo only, no GitHub release.
PUBLISH_GITHUB=0

export APP_NAME BUNDLE_ID DMG_NAME PUBLISH_GITHUB
