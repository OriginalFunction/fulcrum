#!/bin/bash
#
# Builds, signs, notarizes and packages Fulcrum for public download.
#
#   scripts/release.sh [keychain-profile]     # default profile: fulcrum
#
# Prerequisites, both of which live in the keychain and are never in this repo:
#
#   1. A "Developer ID Application" certificate for the team. Xcode ->
#      Settings -> Accounts -> Manage Certificates -> + -> Developer ID
#      Application. Check with:  security find-identity -v -p codesigning
#
#   2. Notarization credentials stored under a profile name:
#        xcrun notarytool store-credentials "fulcrum" \
#          --key AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#      (or --apple-id / --team-id / --password with an app-specific password)
#
# Why each step exists, since most of them fail silently if skipped:
#
#   --options=runtime   Notarization REJECTS a build without the hardened
#                       runtime. The Xcode project sets it too; passing it here
#                       as well means a release cannot be produced without it
#                       even if the project setting is later changed.
#   --timestamp         A signature without a secure timestamp stops validating
#                       the day the certificate expires, rather than remaining
#                       valid for everything signed while it was live.
#   CODE_SIGN_STYLE     The project uses Automatic, which picks the *Apple
#     =Manual           Development* certificate. That signs and verifies
#                       happily, notarizes, and then fails on someone else's
#                       Mac. Selecting the identity explicitly is the only way
#                       to be sure which one was used.
#   staple              Puts the notarization ticket inside the artifact, so
#                       Gatekeeper accepts it offline. Without it a first launch
#                       on a machine with no network is rejected.
#   clean tree + tag    The script refuses to run on a dirty tree and tags the
#                       release itself, recording the DMG's md5 and byte count in
#                       the tag message. v1.0 shipped untagged; when a bug in it
#                       had to be debugged a day later, the build commit could
#                       only be reconstructed from the DMG's mtime, and the tree
#                       it was built from could not be established at all.
#   CODE_SIGN_INJECT_   Xcode otherwise injects `com.apple.security.
#     BASE_ENTITLEMENTS   get-task-allow` — the entitlement that lets a debugger
#     =NO                 attach — into Release builds too. Notarization rejects
#                       it outright: "The executable requests the
#                       com.apple.security.get-task-allow entitlement." This
#                       repo's own first notarization attempt failed on exactly
#                       that, after the build, the signature and every local
#                       check had passed.
set -euo pipefail

PROFILE="${1:-fulcrum}"
IDENTITY="Developer ID Application: Original Function Inc. (AVWF3ADBT2)"
SCHEME="Fulcrum"
PROJECT="Fulcrum/Fulcrum.xcodeproj"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/release"
DERIVED="$OUT/DerivedData"
APP="$DERIVED/Build/Products/Release/Fulcrum.app"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

say "Checking prerequisites"
IDENTITIES="$(security find-identity -v -p codesigning)"
case "$IDENTITIES" in
  *"Developer ID Application"*) ;;
  *) fail "no Developer ID Application certificate in the keychain" ;;
esac
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "no notarization credentials stored under profile '$PROFILE' — see the header of this script"

# A release tag has to mean something, and it can only mean "this commit built
# that artifact" if the tree was clean when the artifact was built. v1.0 shipped
# untagged from a working tree nobody recorded; a day of debugging a v1.0 bug
# later, the build commit had to be reconstructed from the DMG's mtime.
#
# `--porcelain` covers staged, unstaged and untracked alike. Untracked files are
# included deliberately: a source file that was never added is exactly the kind
# of thing that builds locally and is missing from the tag.
[ -z "$(git status --porcelain)" ] \
  || fail "working tree is not clean — commit or stash before releasing, so the tag identifies what shipped"

# Captured BEFORE the script edits site/www/index.html below. That edit is a
# real change to the tree, so reading HEAD later would still be correct, but
# reading it here makes the ordering explicit rather than incidental.
COMMIT="$(git rev-parse HEAD)"

say "Running tests"
swift test 2>&1 | tail -3

say "Building and signing with Developer ID"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  build 2>&1 | tail -3

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
BUILD="$(defaults read "$APP/Contents/Info" CFBundleVersion)"
say "Built Fulcrum $VERSION ($BUILD)"

# Checked here rather than before the build, because the version lives in the
# built Info.plist and reading it any earlier means trusting a second source.
# Here still costs only the build — it is ahead of notarization, which is the
# slow step and the one that reaches the network.
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  # `$TAG^{}` dereferences to the commit. Without it an ANNOTATED tag resolves
  # to the tag object's own sha, which appears nowhere in `git log` and sends
  # the reader looking for a commit that does not exist.
  fail "$TAG already exists (at $(git rev-parse --short "$TAG^{}")) — bump MARKETING_VERSION, or delete the tag if that release was never published"
fi

# Prove the *right* identity was used. A build signed with the development
# certificate reaches this point looking healthy.
#
# The output is captured into a variable rather than piped into `grep -q`.
# Under `set -o pipefail` that pipeline reports failure even when the grep
# MATCHES: `grep -q` exits the moment it finds one, closing the pipe, so
# `codesign` dies of SIGPIPE with status 141 and pipefail surfaces that as the
# pipeline's result. This script's first run failed exactly that way, on a
# correctly signed build.
DESCRIPTION="$(codesign -dvvv "$APP" 2>&1)"
case "$DESCRIPTION" in
  *"Authority=Developer ID Application"*) ;;
  *) fail "app is not signed with a Developer ID certificate" ;;
esac
case "$DESCRIPTION" in
  *"flags="*"runtime"*) ;;
  *) fail "hardened runtime is not enabled — notarization would reject this" ;;
esac

VERIFICATION="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)"
case "$VERIFICATION" in
  *"satisfies its Designated Requirement"*) ;;
  *) fail "signature does not verify" ;;
esac

# Submits an artifact and does not return until Apple has ACCEPTED it.
#
# `notarytool submit --wait` exits 0 even when the result is Invalid — it
# reports "the submission completed", not "the submission passed". Checking
# only its exit status lets a rejected build sail through to the next step,
# which is how this script first failed: the real error surfaced two commands
# later as an unstaplable app, with the actual reason ("get-task-allow") only
# visible by fetching the log by hand.
notarize() {
  local artifact="$1"
  local output
  output="$(xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" --wait 2>&1)"
  echo "$output"
  local id
  id="$(echo "$output" | awk '/^ *id: /{print $2; exit}')"
  case "$output" in
    *"status: Accepted"*) return 0 ;;
  esac
  printf '\n\033[31mNotarization did not succeed. Apple'"'"'s reasons:\033[0m\n' >&2
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
  fail "notarization of $(basename "$artifact") was rejected"
}

say "Notarizing the app"
ZIP="$OUT/Fulcrum-$VERSION.zip"
# ditto, not zip(1): it preserves the bundle's symlinks and extended
# attributes, which a plain zip flattens and notarization then rejects.
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP" || fail "could not staple the app"
rm -f "$ZIP"

say "Building the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # the drag-to-install affordance
DMG="$OUT/Fulcrum-$VERSION.dmg"
hdiutil create -volname "Fulcrum" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

say "Notarizing the disk image"
# The app inside is already stapled, so it survives being dragged out. The DMG
# is notarized separately because Gatekeeper also checks the downloaded
# container itself.
codesign --sign "$IDENTITY" --timestamp "$DMG" || fail "could not sign the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG" || fail "could not staple the disk image"

say "Verifying the way Gatekeeper will"
ASSESSMENT="$(spctl -a -vvv -t install "$APP" 2>&1 || true)"
case "$ASSESSMENT" in
  *accepted*) ;;
  *) fail "Gatekeeper rejected the app: $ASSESSMENT" ;;
esac
xcrun stapler validate "$APP" || fail "the app has no valid stapled ticket"
xcrun stapler validate "$DMG" || fail "the disk image has no valid stapled ticket"

say "Tagging the release"
# Placed here, after stapling, because this is the first point at which a
# shippable artifact exists: everything above can fail, and a tag for a release
# that was never produced is worse than no tag.
#
# The digest and byte count go in the message so the tag answers the question
# that actually gets asked later — "is the file on the CDN the one this commit
# built?" — without needing the build machine or the DMG that produced it.
DMG_MD5="$(md5 -q "$DMG")"
DMG_BYTES="$(stat -f%z "$DMG")"
git tag -a "$TAG" "$COMMIT" -m "Fulcrum $VERSION ($BUILD)

Signed Developer ID (team AVWF3ADBT2), notarized and stapled by
scripts/release.sh.

  $(basename "$DMG")  $DMG_BYTES bytes  md5 $DMG_MD5

Compare against what is published:
  curl -sI https://fulcrum.originalfunction.com/download/$(basename "$DMG")
The ETag of a single-part S3 upload is its md5." \
  || fail "could not create tag $TAG"
echo "  tagged $TAG at $(git rev-parse --short "$COMMIT")"

# Pushed, but not fatally: the tag exists locally either way, and this developer
# works from behind a VPN where a push can fail for reasons that have nothing to
# do with the release. Failing the whole run here would throw away a good build.
if git push origin "$TAG" 2>/dev/null; then
  echo "  pushed $TAG to origin"
else
  printf '\033[33m  could not push %s — run: git push origin %s\033[0m\n' "$TAG" "$TAG"
fi

say "Updating the site's download link"
# The page in site/www/ is the source of truth for what the site advertises,
# so the version and filename are rewritten here rather than being edited by
# hand — a published page pointing at a DMG that no longer exists is a broken
# download nobody notices until someone reports it.
PAGE="$ROOT/site/www/index.html"
/usr/bin/sed -i '' \
  -e "s|href=\"/download/Fulcrum-[^\"]*\.dmg\"|href=\"/download/Fulcrum-$VERSION.dmg\"|" \
  -e "s|Version [0-9][^ ]* ·|Version $VERSION ·|" \
  "$PAGE"
grep -q "Fulcrum-$VERSION.dmg" "$PAGE" || fail "could not update the download link in $PAGE"

say "Done"
echo "  $DMG"
echo "  tagged $TAG"
echo
echo "site/www/index.html now points at $VERSION and is UNCOMMITTED. That edit is"
echo "deliberately not in $TAG — the tag identifies the sources that built the app,"
echo "and the page is not one of them. Commit it before deploying the site stack."
echo
echo "Verify it the way a stranger will — a quarantined copy, not this one,"
echo "which the build process has already blessed:"
echo
echo "  xattr -w com.apple.quarantine '0081;00000000;Safari;' \"$DMG\""
echo "  open \"$DMG\"     # drag to Applications, launch, expect no warning"
echo
echo "Then publish (needs the site stack deployed):"
echo
echo "  scripts/publish.sh \"$DMG\""
