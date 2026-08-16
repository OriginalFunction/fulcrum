#!/bin/bash
#
# Uploads a notarized DMG to the download site and invalidates the CDN.
#
#   scripts/publish.sh build/release/Fulcrum-1.0.dmg
#
# Deliberately separate from the CDK stack. The stack owns the page; this owns
# `/download/`. `BucketDeployment` runs with `prune: false` precisely so a site
# deploy does not delete the release artifacts uploaded here — and so that
# publishing a build does not require a CloudFormation change.
#
# The DMG is not committed to the repo: it is rebuilt per version, is a
# megabyte-scale binary, and git is the wrong place for either.
set -euo pipefail

DMG="${1:-}"
STACK="FulcrumSite"
REGION="us-east-1"

fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

[ -n "$DMG" ] || fail "usage: scripts/publish.sh <path-to-dmg>"
[ -f "$DMG" ] || fail "no such file: $DMG"

say "Checking the disk image is releasable"
# Publishing an unnotarized DMG is the one mistake that cannot be walked back
# quietly: it is downloaded and blocked on someone else's Mac before anyone
# here notices. `stapler validate` is what proves the ticket is attached.
xcrun stapler validate "$DMG" >/dev/null 2>&1 \
  || fail "$(basename "$DMG") has no stapled notarization ticket — run scripts/release.sh"

say "Looking up the site's bucket and distribution"
OUTPUTS="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs' --output json 2>/dev/null)" \
  || fail "stack $STACK is not deployed — run 'cdk deploy' in site/infra first"

BUCKET="$(echo "$OUTPUTS" | /usr/bin/python3 -c 'import json,sys; print(next(o["OutputValue"] for o in json.load(sys.stdin) if o["OutputKey"]=="BucketName"))')"
DIST="$(echo "$OUTPUTS" | /usr/bin/python3 -c 'import json,sys; print(next(o["OutputValue"] for o in json.load(sys.stdin) if o["OutputKey"]=="DistributionId"))')"
echo "  bucket:       $BUCKET"
echo "  distribution: $DIST"

say "Uploading"
NAME="$(basename "$DMG")"
aws s3 cp "$DMG" "s3://$BUCKET/download/$NAME" \
  --region "$REGION" \
  --content-type application/x-apple-diskimage \
  --cache-control "public, max-age=31536000, immutable" \
  || fail "upload failed"

say "Invalidating the download path"
# Only /download/*: the page itself is invalidated by the CDK deployment that
# publishes it, and a whole-distribution invalidation on every release would
# throw away the cache for no reason.
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/download/*" \
  --region "$REGION" --query 'Invalidation.Id' --output text \
  || fail "invalidation failed"

say "Published"
echo "  https://fulcrum.originalfunction.com/download/$NAME"
echo
echo "The page links to whatever version scripts/release.sh last wrote into"
echo "site/www/index.html — deploy the site stack if that link has changed."
