#!/bin/bash
#
# Publishes a source-only snapshot of Fulcrum to the PUBLIC GitHub repository.
#
#   scripts/publish-source.sh                    # dry run: assemble, verify, report
#   scripts/publish-source.sh --version 1.1      # dry run for a specific version
#   scripts/publish-source.sh --push             # actually publish
#
# Bitbucket stays primary and private: it holds the full history, the design
# docs, the agent ledgers and the site's infrastructure. GitHub gets a
# source-only mirror with ONE SQUASHED COMMIT PER RELEASE, produced by this
# script. The two histories deliberately do not correspond; the private commit
# each public one was built from is recorded in the public commit message, and
# that is the only path back.
#
# Why each guard exists, because publishing is the one operation here that
# cannot be undone. Public git is scraped and mirrored within hours: a force
# push does not unpublish anything, and neither does deleting the repository.
#
#   allow-list         The set of published paths is enumerated positively,
#                      below. A deny-list would publish every directory added
#                      in the future by default, and the failure mode of a
#                      deny-list is silent — nobody notices the leak until it
#                      is already mirrored. The cost of this choice is that a
#                      new published directory has to be added here by hand.
#                      That cost is the point.
#   content gate       After assembly and BEFORE any network call, every
#                      published file is scanned for the names of the
#                      developer's employer's systems and for credential
#                      shapes. Any hit is fatal, never a warning: a warning on
#                      an irreversible operation is a warning nobody reads
#                      twice. This is the property the whole design rests on.
#   dry run default    Assembling and verifying is free and reversible;
#                      pushing is neither. The flag has to be typed.
#   clean tree         Same reason scripts/release.sh refuses one: the public
#                      commit claims to be the private commit's tree, and that
#                      claim is false the moment anything is uncommitted.
#                      Assembly reads HEAD via `git archive`, never the working
#                      tree, so a dirty tree would silently publish something
#                      other than what the recorded sha contains.
#   git archive        Reads the committed tree directly. It touches no
#                      checkout, takes no branch locks and needs no worktree of
#                      its own, so this is safe to run while other worktrees of
#                      this repository are busy.
#
# The gate's patterns match credential SHAPES rather than the words that
# describe them. That is deliberate: docs/testing/capture-log-corpus.sh is
# published and contains the literal strings `password`, `bearer`, `AKIA...`
# and `eyJ...` as part of its own redaction regexes, and Sources contains
# `Bearer \(instance.token)`. A word-matching gate fires on all of those, and a
# gate that cries wolf on every run is a gate that gets commented out.
#
# Note also what is NOT written here: the AWS account id and certificate ARN
# that site/infra carries are matched by shape, not by value. Hard-coding them
# into a gate would publish them in this script, which is itself published.
set -euo pipefail

# The public remote. Overridable so the assembly and the gate can be exercised
# against a scratch repository without involving GitHub.
REMOTE="${FULCRUM_PUBLIC_REMOTE:-git@github.com:OriginalFunction/fulcrum.git}"
BRANCH="${FULCRUM_PUBLIC_BRANCH:-main}"

# ---------------------------------------------------------------------------
# The allow-list: everything the public repository is permitted to contain.
# ---------------------------------------------------------------------------
#
#   Sources/          FulcrumKit, the library under test. The point of the
#                     public repo.
#   Fulcrum/          The app target and its Xcode project. Carries the Team ID
#                     in DEVELOPMENT_TEAM, which is already readable in the
#                     signature of every shipped build, so it is not a secret.
#   Tests/            Published deliberately. The tests are the argument for
#                     the design; without them the doc comments cite evidence a
#                     reader cannot check. The fixtures are synthesized
#                     (see docs/testing/generate-log-corpus.swift).
#   Package.swift     Required to build.
#   Package.resolved  Pins Yams to the revision the tests were run against. A
#                     public checkout without it resolves to whatever Yams has
#                     released since, which is a different tree than the one
#                     this snapshot claims to be.
#   README.md         The front door.
#   LICENSE           Without it the code is not usable by anyone.
#   .gitignore        Keeps a public contributor's build output out of their
#                     diffs. Names .superpowers/, which is only the name of a
#                     directory that is not published.
#   docs/testing/     How the log corpus is generated and how the capture it
#                     replaced was redacted. Honest public content, and the
#                     provenance argument for the fixtures above.
#   scripts/          Release tooling, including this script. Holds no secret:
#                     credentials live in the keychain, and the bucket and
#                     distribution are looked up from CloudFormation at run
#                     time rather than written down.
#
# Excluded, and why:
#
#   site/infra/       CDK for the download site. Carries the AWS account id, an
#                     ACM certificate ARN and a Route53 zone id. Identifiers
#                     rather than secrets, but they are the developer's
#                     infrastructure and they belong to no one reading the app.
#   site/www/         Published to the CDN already; nothing to gain, and it
#                     tracks a version this snapshot does not control.
#   docs/superpowers/ Internal design docs and specs.
#   .superpowers/     Agent ledgers. Gitignored, so `git archive` would not see
#                     them anyway — the allow-list is what actually excludes
#                     them, and the path gate below fails on the name.
#   design/           Source SVGs for the logo and the menu bar states. Not
#                     needed to build; add here if the artwork is ever meant to
#                     be reusable.
PUBLISHED_PATHS=(
  "Sources"
  "Fulcrum"
  "Tests"
  "Package.swift"
  "Package.resolved"
  "README.md"
  "LICENSE"
  ".gitignore"
  "docs/testing"
  "scripts"
)

# ---------------------------------------------------------------------------
# The content gate.
# ---------------------------------------------------------------------------
# Parallel arrays rather than an associative array: macOS ships bash 3.2, which
# has no `declare -A`, and this script must run with /bin/bash.
#
# `\<` is a word-start anchor understood by both BSD and GNU grep. It is what
# keeps the first pattern below from matching "permanent" and "determine" — the
# reason a naive scan of this repository reports a hundred false hits.
#
# The single-character brackets are not decoration. This script is published,
# and the gate scans everything published INCLUDING ITSELF, so a pattern
# written as a plain literal would match its own definition and fail every run
# on a correct export. A bracketed first character matches exactly the same
# text as the bare literal would while not BEING that literal — the same trick
# as `ps | grep [s]shd`. The alternative was to
# exempt this file from the scan, and the one file nobody scans should not be
# the file that defines the scan.
GATE_NAMES=(
  "the employer's system name"
  "the employer's tenant slug"
  "the employer's internal tool"
  "the developer's account name"
  "a developer home directory"
  "an AWS ARN carrying an account id"
  "an AWS account id assignment"
  "an AWS access key id"
  "a JWT"
  "a private key block"
  "a password assignment"
  "a bearer token"
  "a GitHub token"
  "a Slack token"
)
GATE_PATTERNS=(
  '\<[e]rma'
  '\<[a]cme\>'
  'ai-internal[-]tool'
  '[r]ay[._-]?hwang'
  '/Users/[r]ay'
  'arn:aws:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}'
  '[Aa]ccount[^A-Za-z0-9]{1,4}[0-9]{12}'
  '\<(AKIA|ASIA)[0-9A-Z]{16}\>'
  'eyJ[A-Za-z0-9_-]{16,}'
  'BEGIN [A-Z ]*PRIVATE KEY'
  'password[[:space:]]*='
  'Bearer [A-Za-z0-9._-]{16,}'
  'gh[pousr]_[A-Za-z0-9]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
)

# Checked against file NAMES only, never contents.
#
# `superpowers` has to live here rather than above: the allow-list at the top of
# this script discusses docs/superpowers/ by name, this script is published, and
# a content rule would therefore fire on every run of a correct export. What
# actually matters is that no file is ever named that, which is what this
# catches. The signing material is the same shape of rule — .gitignore already
# excludes it, and this is the check that survives someone editing .gitignore.
PATH_GATE_NAMES=(
  "an internal-only directory"
  "signing or notarization material"
  "a macOS metadata file"
)
PATH_GATE_PATTERNS=(
  'superpowers'
  '(\.p8|\.p12|\.cer|\.mobileprovision)$|/AuthKey_'
  '\.DS_Store$'
)

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

PUSH=0
VERSION=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --yes) ASSUME_YES=1 ;;
    --version) shift; VERSION="${1:-}"; [ -n "$VERSION" ] || fail "--version needs a value" ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Everything is assembled under one temp directory that is always removed, so a
# failed run cannot leave a half-built export lying around to be mistaken for a
# good one later.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fulcrum-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXPORT="$WORK/export"
mkdir -p "$EXPORT"

say "Checking the tree"
[ -z "$(git status --porcelain)" ] \
  || fail "working tree is not clean — commit or stash first, so the published snapshot is the commit it names"

COMMIT="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"

if [ -z "$VERSION" ]; then
  # A release tag is the only thing in this repository that asserts "this tree
  # shipped". Publishing an arbitrary commit as a release is exactly the kind
  # of thing that is discovered months later, so it has to be stated
  # explicitly rather than guessed.
  TAG_AT_HEAD="$(git tag --points-at HEAD | grep '^v[0-9]' | head -1 || true)"
  [ -n "$TAG_AT_HEAD" ] \
    || fail "HEAD ($SHORT) carries no v* release tag — run scripts/release.sh first, or pass --version X.Y to publish this commit deliberately"
  VERSION="${TAG_AT_HEAD#v}"
fi
echo "  version:        $VERSION"
echo "  source commit:  $COMMIT"

say "Assembling the export"
# Checked one at a time so that a typo in the allow-list names itself, rather
# than surfacing as a pathspec error listing all ten entries — or, worse, as a
# published tree that is quietly missing a directory.
for path in "${PUBLISHED_PATHS[@]}"; do
  git cat-file -e "HEAD:$path" 2>/dev/null \
    || fail "allow-listed path is not in HEAD: $path"
done

# `git archive` reads the committed tree. It never consults the working tree or
# the index, so this cannot pick up an uncommitted file and cannot disturb any
# checkout of this repository, including one that is busy.
git archive --format=tar HEAD -- "${PUBLISHED_PATHS[@]}" | (cd "$EXPORT" && tar -xf -)

FILE_COUNT="$(find "$EXPORT" -type f | wc -l | tr -d ' ')"
[ "$FILE_COUNT" -gt 0 ] || fail "the export is empty"
echo "  $FILE_COUNT files"

say "Scanning the export for anything that must not be published"
# The gate. Both halves of it are fatal:
#
#   paths     A file whose NAME leaks is not caught by scanning contents.
#   contents  `-I` skips binary files, so they are listed separately below and
#             have to be recognised by eye; there is no way to scan a PNG for a
#             hostname and the honest thing is to say so rather than to imply
#             the scan covered it.
HITS=0
NAMES="$(cd "$EXPORT" && find . -type f | sed 's|^\./||')"

i=0
while [ $i -lt ${#PATH_GATE_PATTERNS[@]} ]; do
  found="$(echo "$NAMES" | grep -iE -- "${PATH_GATE_PATTERNS[$i]}" || true)"
  if [ -n "$found" ]; then
    printf '\n\033[31m  %s — in a FILE NAME:\033[0m\n' "${PATH_GATE_NAMES[$i]}"
    echo "$found" | sed 's|^|    |'
    HITS=$((HITS + 1))
  fi
  i=$((i + 1))
done

i=0
while [ $i -lt ${#GATE_PATTERNS[@]} ]; do
  name="${GATE_NAMES[$i]}"
  pattern="${GATE_PATTERNS[$i]}"

  # Output is captured rather than piped into grep -q or `if grep`: under
  # `set -o pipefail` an early-exiting reader turns a MATCH into a failed
  # pipeline, which is how scripts/release.sh once failed on a healthy build.
  paths="$(echo "$NAMES" | grep -iE -- "$pattern" || true)"
  if [ -n "$paths" ]; then
    printf '\n\033[31m  %s — in a FILE NAME:\033[0m\n' "$name"
    echo "$paths" | sed 's|^|    |'
    HITS=$((HITS + 1))
  fi

  found="$(cd "$EXPORT" && grep -rIEn -- "$pattern" . 2>/dev/null || true)"
  if [ -n "$found" ]; then
    printf '\n\033[31m  %s (/%s/):\033[0m\n' "$name" "$pattern"
    # Truncated: the point is to name the file and line, not to reprint a
    # credential into a terminal and a scrollback buffer.
    echo "$found" | sed 's|^\./||' | cut -c1-160 | head -20
    COUNT="$(echo "$found" | wc -l | tr -d ' ')"
    [ "$COUNT" -gt 20 ] && echo "    … and $((COUNT - 20)) more"
    HITS=$((HITS + 1))
  fi
  i=$((i + 1))
done

if [ "$HITS" -gt 0 ]; then
  fail "the content gate found $HITS forbidden pattern(s) — NOTHING was pushed.
  Fix the tree and commit the fix; do not edit the export, and do not relax the
  gate to get past it. Publishing is irreversible, and this is the check that
  makes the difference between a private mistake and a public one."
fi
echo "  clean: no forbidden pattern in any of the $FILE_COUNT files"

# Asked of file(1) rather than of grep: BSD grep's `-I` SKIPS a binary file
# entirely, so it appears in neither `-l` nor `-L` output, and a list built
# from `grep -L` reports empty text files as binary while silently omitting
# every actual image. Zero-byte files are dropped first because file(1) calls
# those binary too, and an empty file is not a thing anyone needs to inspect.
BINARIES="$(cd "$EXPORT" && find . -type f -size +0c | sed 's|^\./||' | sort | while IFS= read -r f; do
  if [ "$(file -b --mime-encoding "$f")" = "binary" ]; then echo "$f"; fi
done)"
if [ -n "$BINARIES" ]; then
  echo
  echo "  Binary files, which no text scan can vouch for — check the list:"
  echo "$BINARIES" | sed 's|^|    |'
fi

say "What would be published"
echo "  remote:  $REMOTE ($BRANCH)"
echo "  version: $VERSION"
echo "  from:    $COMMIT"
echo "  size:    $(du -sh "$EXPORT" | cut -f1)"
echo
(cd "$EXPORT" && find . -type f | sed 's|^\./||' | sort | awk '{print "    " $0}')

MESSAGE="Fulcrum $VERSION

Source-only snapshot, published by scripts/publish-source.sh.

Produced from $COMMIT in the private repository, which holds the full
history. This repository carries one squashed commit per release, so its
history does not correspond to that one commit for commit; the sha above is
the way back to the internal history of this release."

if [ "$PUSH" -eq 0 ]; then
  say "Dry run — nothing was pushed"
  echo "  This run reached the network not at all."
  echo "  Publish with:  scripts/publish-source.sh --version $VERSION --push"
  exit 0
fi

# ---------------------------------------------------------------------------
# Past this point the operation is irreversible.
# ---------------------------------------------------------------------------
say "Publishing to $REMOTE"
if [ "$ASSUME_YES" -eq 0 ]; then
  if [ -t 0 ]; then
    printf '\n\033[1mThis publishes %s files to a PUBLIC repository, permanently.\033[0m\n' "$FILE_COUNT"
    printf 'Type the version (%s) to confirm: ' "$VERSION"
    read -r reply
    [ "$reply" = "$VERSION" ] || fail "not confirmed — nothing was pushed"
  else
    # Not a terminal, so nobody is reading the summary above. An unattended
    # publish has to say so in the command line that started it.
    fail "--push with no terminal to confirm at — pass --yes if this is deliberate"
  fi
fi

PUBLIC="$WORK/public"
# A shallow clone: the public history is not needed to add a commit to it, and
# fetching it in full would be the slowest part of the run.
if git clone --depth 1 --branch "$BRANCH" "$REMOTE" "$PUBLIC" 2>/dev/null; then
  echo "  cloned $BRANCH"
else
  # First publish, or a repository whose default branch does not exist yet.
  git clone --depth 1 "$REMOTE" "$PUBLIC" 2>/dev/null || git init -q "$PUBLIC"
  git -C "$PUBLIC" remote add origin "$REMOTE" 2>/dev/null || true
  git -C "$PUBLIC" checkout -q -B "$BRANCH"
  echo "  starting $BRANCH"
fi

if git -C "$PUBLIC" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
  fail "v$VERSION is already published — bump the version, or delete that tag if the release was withdrawn"
fi

# Everything except .git is removed before the export is copied in, so that a
# file deleted privately is deleted publicly too. A copy-over-the-top would
# leave it published forever.
find "$PUBLIC" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
(cd "$EXPORT" && tar -cf - .) | (cd "$PUBLIC" && tar -xf -)

git -C "$PUBLIC" add -A
if git -C "$PUBLIC" diff --cached --quiet; then
  say "Nothing to publish"
  echo "  the public tree already matches this snapshot"
  exit 0
fi

git -C "$PUBLIC" commit -q -m "$MESSAGE"
git -C "$PUBLIC" tag -a "v$VERSION" -m "Fulcrum $VERSION (from $SHORT)"
git -C "$PUBLIC" push -q origin "$BRANCH" || fail "push rejected"
git -C "$PUBLIC" push -q origin "v$VERSION" || fail "tag push rejected"

say "Published"
echo "  $REMOTE  $BRANCH  v$VERSION"
echo "  public commit $(git -C "$PUBLIC" rev-parse --short HEAD) = private $SHORT"
