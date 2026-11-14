#!/bin/bash
# End-to-end release: build → sign → dmg → notarize → staple → GitHub
# Release + Forgejo Release. Uploads two assets per release:
#   - BlueConnect-Admin.dmg     (the Mac app, drag-installer)
#   - BlueConnectHelper.pkg     (Munki-deployable chat helper + LaunchAgent;
#                                URL is hard-linked from the in-app
#                                "GUI Helper" Quick Action)
#
# Requires .env-sign with SIGN_ID, PKG_SIGN_ID, NOTARY_PROFILE,
# GITHUB_REPO populated. Forgejo upload is gated on FORGEJO_BASE /
# FORGEJO_TOKEN — script skips it silently if those aren't set.
#
# Requires the `gh` CLI (https://cli.github.com) authenticated with repo scope.
#
# Usage:  bash release.sh v0.2.0
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:?usage: $0 <version>  e.g. v1.0.0}"

if [[ ! -f "$PROJECT_ROOT/.env-sign" ]]; then
    echo "✖ missing .env-sign — see build-app.sh for the variables it expects" >&2
    exit 1
fi
set -a; source "$PROJECT_ROOT/.env-sign"; set +a

# Per-branch app identity (APP_NAME / BUNDLE_ID / DMG_NAME / PUBLISH_GITHUB),
# sourced AFTER .env-sign so it wins. On main this is the "Edict MDM"
# identity with PUBLISH_GITHUB=0 (Forgejo-only); on release/1.5 it's the
# public "BlueConnect Admin" identity. Absent → fall back to .env-sign with
# GitHub publishing on.
if [[ -f "$PROJECT_ROOT/build-identity.sh" ]]; then
    source "$PROJECT_ROOT/build-identity.sh"
fi
PUBLISH_GITHUB="${PUBLISH_GITHUB:-1}"
# Remotes the release tag is pushed to. build-identity.sh sets this per
# branch: main (Edict) = "origin edict"; release/1.5 = "github origin".
TAG_REMOTES="${TAG_REMOTES:-github origin}"
# Releases are drafts unless RELEASE_DRAFT=0 (publish only on an explicit ask).
RELEASE_DRAFT="${RELEASE_DRAFT:-1}"

: "${SIGN_ID:?SIGN_ID required for a release build}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE required for notarization}"
# GitHub repo is only required when we're actually publishing there (v1.x).
# v2 (PUBLISH_GITHUB=0) releases privately to Forgejo only.
if [[ "$PUBLISH_GITHUB" == "1" ]]; then
    : "${GITHUB_REPO:?GITHUB_REPO required for upload (format: owner/repo)}"
fi
echo "▶ identity: $APP_NAME ($BUNDLE_ID)  publish-github=$PUBLISH_GITHUB"

DMG_NAME="${DMG_NAME:-BlueConnect-Admin.dmg}"
DMG="$PROJECT_ROOT/$DMG_NAME"
HELPER_PKG_NAME="${HELPER_PKG_NAME:-BlueConnectHelper.pkg}"
HELPER_PKG="$PROJECT_ROOT/$HELPER_PKG_NAME"

# Derive Info.plist VERSION from the tag (strip leading 'v'). The build
# number is build-app.sh's running counter (.build-number), same as dev
# builds, so re-cutting a release draft never reuses a number.
export VERSION="${TAG#v}"
unset BUILD_NUMBER_EXPLICIT
echo "▶ release VERSION=$VERSION (tag=$TAG)"

bash "$PROJECT_ROOT/make-dmg.sh"

echo "▶ notarize (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶ staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "▶ git tag $TAG"
git tag "$TAG" 2>/dev/null || echo "  (tag already exists, skipping)"
# Push the tag to BOTH remotes — github (public mirror) and origin
# (Forgejo home). Older release.sh only pushed to github; the v1.4.0
# cut showed why that's bad. `|| true` per remote so a single-remote
# failure doesn't abort the entire release.
echo "▶ push tag to: $TAG_REMOTES"
for remote in $TAG_REMOTES; do
    git push "$remote" "$TAG" 2>/dev/null || echo "  ($remote tag push skipped)"
done

# Build the Munki-deployable helper pkg (chat client + GUI helper +
# LaunchAgent plist) as the second release asset. The in-app
# "GUI Helper" Quick Action links operators at
# https://github.com/<repo>/releases/download/<tag>/BlueConnectHelper.pkg —
# they'd hit a 404 if we forgot to build + upload it here.
# `--notarize` makes the pkg builder do its own notarize + staple
# pass (separate notarytool submission from the DMG above).
# PKG_VERSION is exported so the pkg's CFBundleShortVersionString
# matches $VERSION even before the new tag has propagated to
# `git describe`.
echo "▶ build BlueConnectHelper.pkg (notarized + stapled)"
PKG_VERSION="$VERSION" bash "$PROJECT_ROOT/scripts/build-helper-pkg.sh" --notarize

NOTES="${RELEASE_NOTES_FILE:-$PROJECT_ROOT/RELEASE_NOTES.md}"

# GitHub release — public track only. v2 / "Edict MDM" sets
# PUBLISH_GITHUB=0 (via build-identity.sh) so it never lands on the public
# repo; it ships to Forgejo (below) only.
if [[ "$PUBLISH_GITHUB" == "1" ]]; then
echo "▶ gh release create (GitHub)"
# `--latest` is explicit so the release lands as Latest even if a higher
# semver tag exists transiently (e.g. a draft 1.6.0 created out of order
# during testing). Without it gh defers to its automatic latest selection,
# which is "most recent stable by date + semver" — usually right, but a
# stray draft can confuse it. `--prerelease=false` and `--draft=false` are
# defaults but listed so future-us doesn't have to dig through gh's help.
if [[ "$RELEASE_DRAFT" == "1" ]]; then
    GH_STATE=(--draft)
else
    GH_STATE=(--latest --prerelease=false --draft=false)
fi
if [[ -f "$NOTES" ]]; then
    gh release create "$TAG" "$DMG" "$HELPER_PKG" \
        --repo "$GITHUB_REPO" \
        --title "$TAG" \
        --notes-file "$NOTES" \
        "${GH_STATE[@]}"
else
    gh release create "$TAG" "$DMG" "$HELPER_PKG" \
        --repo "$GITHUB_REPO" \
        --title "$TAG" \
        --generate-notes \
        "${GH_STATE[@]}"
fi

if [[ "$RELEASE_DRAFT" == "1" ]]; then
    echo "  ✓ DRAFT created — publish later with:  gh release edit $TAG --repo $GITHUB_REPO --draft=false --latest"
else
# Assert /releases/latest now resolves to this tag. Hard-fail the script
# if not — that's the only signal we get if a draft/prerelease flag slipped
# through, or if GitHub ever changes its latest-selection rule.
echo "▶ verify /releases/latest → $TAG"
LATEST_TAG="$(gh api "/repos/$GITHUB_REPO/releases/latest" --jq .tag_name 2>/dev/null || echo "")"
if [[ "$LATEST_TAG" != "$TAG" ]]; then
    echo "  ✖ /releases/latest returned '$LATEST_TAG', expected '$TAG'" >&2
    echo "    fix with:  gh release edit $TAG --repo $GITHUB_REPO --latest --prerelease=false --draft=false" >&2
    exit 1
fi
echo "  ✓ /releases/latest = $LATEST_TAG"
fi
else
    echo "▶ skipping GitHub release (PUBLISH_GITHUB=0 — private v2 track, Forgejo only)"
fi

# Forgejo release — POST a release record + upload the DMG as an
# asset. Config is optional: skip if FORGEJO_BASE / FORGEJO_TOKEN
# aren't set in .env-sign. The Forgejo repo path is derived from
# the `origin` remote URL: parse the path after the host, strip
# trailing `.git`. Token scope needed: `write:repository`.
if [[ -n "${FORGEJO_BASE:-}" && -n "${FORGEJO_TOKEN:-}" ]]; then
    FORGEJO_REPO_PATH="$(git remote get-url origin | sed -E 's#^https?://[^/]+/##; s#\.git$##')"
    echo "▶ Forgejo release: $FORGEJO_BASE/$FORGEJO_REPO_PATH"
    BODY="$(if [[ -f "$NOTES" ]]; then cat "$NOTES"; else echo "$TAG"; fi)"
    # Forgejo 8.0+ honors `make_latest` (same semantics as GitHub's). Older
    # Forgejo versions ignore the field — safe no-op.
    REL_JSON=$(jq -n \
        --arg tag "$TAG" \
        --arg name "$TAG" \
        --arg body "$BODY" \
        --argjson draft "$([[ "$RELEASE_DRAFT" == "1" ]] && echo true || echo false)" \
        '{tag_name:$tag,name:$name,body:$body,draft:$draft,prerelease:false,make_latest:"true"}')
    REL_RESP=$(curl -sS -X POST \
        -H "Authorization: token $FORGEJO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$REL_JSON" \
        "$FORGEJO_BASE/api/v1/repos/$FORGEJO_REPO_PATH/releases")
    REL_ID=$(echo "$REL_RESP" | jq -r '.id // empty')
    if [[ -z "$REL_ID" ]]; then
        echo "  ⚠ Forgejo release create failed: $REL_RESP"
    else
        echo "  release id: $REL_ID — uploading DMG + helper pkg"
        curl -sS -X POST \
            -H "Authorization: token $FORGEJO_TOKEN" \
            -F "attachment=@$DMG" \
            "$FORGEJO_BASE/api/v1/repos/$FORGEJO_REPO_PATH/releases/$REL_ID/assets?name=$DMG_NAME" \
            > /dev/null
        curl -sS -X POST \
            -H "Authorization: token $FORGEJO_TOKEN" \
            -F "attachment=@$HELPER_PKG" \
            "$FORGEJO_BASE/api/v1/repos/$FORGEJO_REPO_PATH/releases/$REL_ID/assets?name=$HELPER_PKG_NAME" \
            > /dev/null
        echo "  ✅ Forgejo: $FORGEJO_BASE/$FORGEJO_REPO_PATH/releases/tag/$TAG"
    fi
fi

echo "✅ released $TAG → https://github.com/$GITHUB_REPO/releases/tag/$TAG"
