#!/bin/bash
#
# Publishes a source-only snapshot of Fulcrum to the PUBLIC GitHub repository.
#
#   scripts/publish-source.sh                    # dry run: assemble, verify, report
#   scripts/publish-source.sh --version 1.1      # dry run for a specific version
#   scripts/publish-source.sh --from a41d3e7     # dry run for an older private commit
#   scripts/publish-source.sh --push             # actually publish
#   scripts/publish-source.sh --fresh --push     # restart the public history at this commit
#   scripts/publish-source.sh --graft-from REF   # take LICENSE/README from a later commit
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
#   export scrub       A release that predates the scrub commits (32c2891,
#                      a30bd76) still names the developer's employer's systems
#                      in its tree. Those commits are tagged and referenced by
#                      tag messages, so private history is not rewritten to fix
#                      them. The substitutions are replayed onto the EXPORT
#                      instead, from the explicit table below, and the public
#                      commit message says so — a reader comparing the public
#                      tree to the recorded private sha has to be told they are
#                      not byte-identical, and told what differs.
#   comment-only gate  The scrub is only harmless to a reader if it did not
#                      change what the code DOES. Every scrubbed line under
#                      Sources/ and Fulcrum/ is therefore classified, and a
#                      line that is not a comment aborts the run: a scrubbed
#                      release whose sources no longer build the shipped,
#                      notarized binary is a worse lie than not publishing it.
#                      --allow-code-scrub overrides, deliberately verbosely.
#   graft list         An older release predates parts of the allow-list.
#                      Shipping without them is the default; LICENSE and
#                      README.md are the two exceptions, because a public tag
#                      with no licence hands a reader source they have no right
#                      to use. They come from a named later commit, they are
#                      reported as an anachronism at every stage, and the public
#                      commit message says which files they are and that they
#                      are the only ones not derived from the exported sha.
#
# Publishing an OLD release (--from) exists because the download site serves
# 1.0 to anyone who asks, and source that stops at the newest release does not
# let that person read what built the binary they ran.
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
# The graft list: published paths a snapshot may carry from a LATER commit.
# ---------------------------------------------------------------------------
# An older release predates some of the allow-list. Shipping without those files
# is the honest default and is what happens to everything not named here.
#
# These two are the exception, because their absence hurts the reader rather
# than merely informing them:
#
#   LICENSE     4ab30bc added it after v1.0 was tagged. Without it, `git
#               checkout v1.0` in a repository that exists to take issues and
#               pull requests yields source with no grant of rights, forever.
#               Historical accuracy loses to that. It is a deliberate
#               anachronism, and it is stated in the public commit message.
#   README.md   Same commit, and the front door: a tag whose root has no README
#               reads as an abandoned dump rather than as a release.
#
# Taken verbatim from --graft-from (default HEAD) rather than trimmed to what
# the tagged tree actually does. A trimmed README would be a document that was
# never the project's front door at any commit — a fabrication, which is the
# thing this script exists not to produce — and a second README to keep correct
# forever. The claims that postdate the exported ref are named in the public
# commit message instead, where a reader can check them against the tree.
#
# Grafted files go through the scrub and the gate like everything else.
GRAFT_PATHS=(
  "LICENSE"
  "README.md"
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

# ---------------------------------------------------------------------------
# The export scrub.
# ---------------------------------------------------------------------------
# Replays, onto the assembled export only, the substitutions that 32c2891 and
# a30bd76 made to the tree AFTER v1.0 was tagged. Exporting a commit older than
# those two otherwise trips the gate on names the private history is entitled to
# keep.
#
# Rules this table follows, all of them load-bearing:
#
#   one naming scheme   Every replacement is the one a30bd76 already chose:
#                       northwind for the project and its services, contoso for
#                       the tenant, /Users/dev for the checkout. Inventing a
#                       second fictional world would make the public repository
#                       read as though two different systems were being
#                       described across two releases of the same app.
#   measurements stay   Where a comment records something MEASURED against a
#                       name, the replacement preserves the measurement. The
#                       old resource name below and its replacement,
#                       `northwind-render-shared-build`, are both 29 characters,
#                       which is the number the log pane's 220pt resource column
#                       is justified by; a shorter replacement would leave the
#                       comment citing evidence that no longer supports it.
#   claims stay true    Where a comment claimed a literal was captured verbatim
#                       and the scrub makes that false, the comment is rewritten
#                       to say which part still is — the shape, not the names.
#                       Those are the multi-line entries at the top.
#   literal, not regex  Matched with quotemeta, so nothing here can match more
#                       than it says. Ordered most-specific first: the path
#                       entry must run before the bare project name it contains.
#   idempotent          Nothing a rule produces is matched by any rule,
#                       including itself, so a ref that was already scrubbed
#                       (anything at or after a30bd76) exports unchanged and
#                       the scrub reports zero replacements.
#
# Parallel arrays again, for bash 3.2. $'…' carries the embedded newlines of the
# prose rewrites. As with the gate patterns above, this file is itself
# published and itself scrubbed-scanned, so the forbidden strings appear here
# with a bracketed first character — a scrub table written in plain literals
# would be edited by its own scrub.
SCRUB_FROM=()
SCRUB_TO=()
scrub_rule() { SCRUB_FROM+=("$1"); SCRUB_TO+=("$2"); }

# Prose whose claim the scrub would otherwise falsify.
scrub_rule \
$'    // Captured VERBATIM from the developer\'s own project (tilt instance on port\n    // 10350) on 2026-08-12 — not a reconstruction. This is the exact shape the\n    // log pane has to render: nested objects, an array of objects, an array of\n    // arrays of strings, a 13-digit integer timestamp, fractional and integer\n    // numbers, and a zero.' \
$'    // The STRUCTURE is verbatim from a real CloudWatch EMF blob captured off a\n    // tilt instance on port 10350 on 2026-08-12 — not a reconstruction. Only the\n    // service, namespace and tenant names are fictional; every structural feature\n    // the parser is tested on is untouched, which is what this test reads. That\n    // shape is what the log pane has to render: nested objects, an array of\n    // objects, an array of arrays of strings, a 13-digit integer timestamp,\n    // fractional and integer numbers, and a zero.'
scrub_rule \
$'    // [e]rma: 49 resources, 2 errored, 2 pending, 45 healthy.' \
$'    // The counts tilt\'s own header showed for the 49-resource project this was\n    // measured against: 49 resources, 2 errored, 2 pending, 45 healthy.'
scrub_rule \
$'/// the blocks beneath it — the shape captured from a real `login-bff` stream,
/// with the emitting service's name replaced by a fictional one:' \
$'/// the blocks beneath it — the shape captured from a real `login-bff` stream,\n/// with the emitting service\'s name replaced by a fictional one:'
scrub_rule \
$'# 1. Compact single-line objects, the shape [e]rma\'s CloudWatch EMF blobs take.' \
$'# 1. Compact single-line objects, the shape a CloudWatch EMF blob takes.'

# Names. Longest first; the two path rules must precede the bare project name.
scrub_rule 'ai-internal[-]tool-shared-build' 'northwind-render-shared-build'
scrub_rule 'ai-internal[-]tool-api'          'ai-api'
scrub_rule '/Users/r/Projects/[e]rma-claude-2' '/Users/dev/src/northwind'
scrub_rule '/Users/[r]ay/project'            '/Users/dev/project'
scrub_rule '[e]rma-compliance-service'       'northwind-render-service'
scrub_rule '[e]rma-platform-service'         'northwind-catalog-service'
scrub_rule '[e]rma-tenant-service'           'northwind-console-service'
scrub_rule '[e]rma-login-service'            'northwind-account-service'
scrub_rule '[e]rma-claude-2'                 'northwind'
scrub_rule '[E]RMA/Database'                 'Northwind/Database'
scrub_rule 'contoso-master'               'contoso-master'
scrub_rule '"[a]cme"'                        '"contoso"'

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$1" >&2; exit 1; }

# The scrub's effect on one file, as `<` old / `>` new lines. Both `diff` (files
# differ) and `grep` (nothing matched) exit non-zero on results this script
# treats as ordinary, and `set -o pipefail` would turn either into a dead run —
# the same trap the gate loop documents above. Swallowed here once, in one
# place, rather than at each of the three call sites.
scrub_diff() { diff "$RAW/$1" "$EXPORT/$1" 2>/dev/null | grep '^[<>]' || true; }

PUSH=0
VERSION=""
ASSUME_YES=0
FROM=""
FRESH=0
ALLOW_CODE_SCRUB=0
GRAFT_FROM=""
GRAFT_NOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1 ;;
    --yes) ASSUME_YES=1 ;;
    --fresh) FRESH=1 ;;
    --allow-code-scrub) ALLOW_CODE_SCRUB=1 ;;
    --version) shift; VERSION="${1:-}"; [ -n "$VERSION" ] || fail "--version needs a value" ;;
    --from) shift; FROM="${1:-}"; [ -n "$FROM" ] || fail "--from needs a commit-ish" ;;
    --graft-from) shift; GRAFT_FROM="${1:-}"; [ -n "$GRAFT_FROM" ] || fail "--graft-from needs a commit-ish" ;;
    --graft-note) shift; GRAFT_NOTE="${1:-}"; [ -n "$GRAFT_NOTE" ] || fail "--graft-note needs a value" ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
# Still required with --from, where the export does not read the working tree
# at all. The reason changes rather than disappearing: the scrub table applied
# below is read from the WORKING COPY of this script, so a dirty tree means the
# scrub that ran is not the scrub any commit records, and the "produced by
# scripts/publish-source.sh" in the public commit message names something that
# exists nowhere.
[ -z "$(git status --porcelain)" ] \
  || fail "working tree is not clean — commit or stash first, so the published snapshot is the commit it names"

# The ref being exported. HEAD unless --from says otherwise; resolved to a full
# sha immediately so everything downstream — the archive, the message, the tag —
# names one immutable object rather than a name that could move mid-run.
SOURCE_REF="${FROM:-HEAD}"
git rev-parse -q --verify "$SOURCE_REF^{commit}" >/dev/null 2>&1 \
  || fail "--from: not a commit in this repository: $FROM"
COMMIT="$(git rev-parse "$SOURCE_REF^{commit}")"
SHORT="$(git rev-parse --short "$SOURCE_REF^{commit}")"

if [ -z "$VERSION" ]; then
  # A release tag is the only thing in this repository that asserts "this tree
  # shipped". Publishing an arbitrary commit as a release is exactly the kind
  # of thing that is discovered months later, so it has to be stated
  # explicitly rather than guessed.
  TAG_AT_REF="$(git tag --points-at "$COMMIT" | grep '^v[0-9]' | head -1 || true)"
  [ -n "$TAG_AT_REF" ] \
    || fail "$SHORT carries no v* release tag — run scripts/release.sh first, or pass --version X.Y to publish this commit deliberately"
  VERSION="${TAG_AT_REF#v}"
fi
echo "  version:        $VERSION"
echo "  source commit:  $COMMIT"
[ -n "$FROM" ] && echo "  (asked for:     $FROM)"

say "Assembling the export"
# Checked one at a time so that a typo in the allow-list names itself, rather
# than surfacing as a pathspec error listing all ten entries — or, worse, as a
# published tree that is quietly missing a directory.
#
# The typo check is against HEAD, always, even when exporting something older:
# a name misspelled here is missing from EVERY ref, so HEAD is where it shows up
# unambiguously. An older ref legitimately predates some published paths —
# a41d3e7 has no README.md and no LICENSE, because 4ab30bc added them — and that
# absence is history, not a typo. It is reported rather than guessed at, because
# a release published without its LICENSE is worth noticing.
for path in "${PUBLISHED_PATHS[@]}"; do
  git cat-file -e "HEAD:$path" 2>/dev/null \
    || fail "allow-listed path is not in HEAD: $path"
done

GRAFT_REF="${GRAFT_FROM:-HEAD}"
git rev-parse -q --verify "$GRAFT_REF^{commit}" >/dev/null 2>&1 \
  || fail "--graft-from: not a commit in this repository: $GRAFT_FROM"
GRAFT_COMMIT="$(git rev-parse "$GRAFT_REF^{commit}")"
GRAFT_SHORT="$(git rev-parse --short "$GRAFT_REF^{commit}")"

ARCHIVE_PATHS=()
ABSENT_PATHS=()
GRAFTED_PATHS=()
for path in "${PUBLISHED_PATHS[@]}"; do
  if git cat-file -e "$COMMIT:$path" 2>/dev/null; then
    ARCHIVE_PATHS+=("$path")
    continue
  fi
  # Absent at the exported ref. Graftable only if the list above names it AND
  # the graft ref actually has it; otherwise the snapshot ships without it and
  # says so. A graft is never silent and never invented — it is always a file
  # that exists at a commit this repository can name.
  graftable=0
  for g in "${GRAFT_PATHS[@]}"; do
    [ "$g" = "$path" ] && graftable=1
  done
  if [ "$graftable" -eq 1 ] && [ "$GRAFT_COMMIT" != "$COMMIT" ] \
     && git cat-file -e "$GRAFT_COMMIT:$path" 2>/dev/null; then
    GRAFTED_PATHS+=("$path")
  else
    ABSENT_PATHS+=("$path")
  fi
done
[ ${#ARCHIVE_PATHS[@]} -gt 0 ] || fail "no allow-listed path exists at $SHORT"
if [ ${#ABSENT_PATHS[@]} -gt 0 ]; then
  printf '\n\033[33m  allow-listed but not present at %s — this snapshot ships without them:\033[0m\n' "$SHORT"
  printf '    %s\n' "${ABSENT_PATHS[@]}"
fi
if [ ${#GRAFTED_PATHS[@]} -gt 0 ]; then
  printf '\n\033[33m  ANACHRONISM — not present at %s, taken from %s instead:\033[0m\n' "$SHORT" "$GRAFT_SHORT"
  printf '    %s\n' "${GRAFTED_PATHS[@]}"
  echo "    These are the only files in this snapshot not derived from $SHORT."
fi

# `git archive` reads the committed tree. It never consults the working tree or
# the index, so this cannot pick up an uncommitted file and cannot disturb any
# checkout of this repository, including one that is busy.
git archive --format=tar "$COMMIT" -- "${ARCHIVE_PATHS[@]}" | (cd "$EXPORT" && tar -xf -)
if [ ${#GRAFTED_PATHS[@]} -gt 0 ]; then
  git archive --format=tar "$GRAFT_COMMIT" -- "${GRAFTED_PATHS[@]}" | (cd "$EXPORT" && tar -xf -)
fi

FILE_COUNT="$(find "$EXPORT" -type f | wc -l | tr -d ' ')"
[ "$FILE_COUNT" -gt 0 ] || fail "the export is empty"
echo "  $FILE_COUNT files"

# ---------------------------------------------------------------------------
# The scrub, applied to the export and to nothing else.
# ---------------------------------------------------------------------------
# A pristine copy is kept so that what follows reports the scrub's effect by
# DIFFING it, rather than by trusting the table to have done what it says.
RAW="$WORK/raw"
cp -R "$EXPORT" "$RAW"

SCRUBBED=0
CODE_HITS=""

say "Scrubbing the export"
# Text files only, decided by file(1) for the same reason the binary listing
# below does: BSD grep silently drops binaries, and rewriting a PNG with a
# text substitution is a corruption nobody would see until someone opened it.
# The list is NUL-delimited so a path containing a space cannot split into two.
SCRUB_LIST="$WORK/text-files"
(cd "$EXPORT" && find . -type f -size +0c -print0 | while IFS= read -r -d '' f; do
  if [ "$(file -b --mime-encoding "$f")" != "binary" ]; then printf '%s\0' "$f"; fi
done) > "$SCRUB_LIST"

SCRUB_TOTAL=0
i=0
while [ $i -lt ${#SCRUB_FROM[@]} ]; do
  # from/to travel through the environment, never through the shell's quoting
  # or perl's parser, so a table entry containing quotes, backslashes, `$` or
  # newlines is matched as the literal text it is. `\Q…\E` is the quotemeta;
  # the bracket-stripping is the same self-scan dodge the gate patterns use,
  # undone here so the table matches `x` while containing `[x]`.
  #
  # xargs may split the file list across several perl runs, so the per-run
  # counts printed on stderr are summed rather than read one at a time.
  count="$(cd "$EXPORT" && SCRUB_F="${SCRUB_FROM[$i]}" SCRUB_T="${SCRUB_TO[$i]}" \
    xargs -0 perl -0777 -pi -e '
      BEGIN { $f = $ENV{SCRUB_F}; $f =~ s/\[(.)\]/$1/g; $t = $ENV{SCRUB_T}; $n = 0 }
      $n += s/\Q$f\E/$t/g;
      END { print STDERR "$n\n" }
    ' < "$SCRUB_LIST" 2>&1 >/dev/null | awk '{ s += $1 } END { print s + 0 }')"
  SCRUB_TOTAL=$((SCRUB_TOTAL + count))
  i=$((i + 1))
done

if [ "$SCRUB_TOTAL" -eq 0 ]; then
  SCRUBBED=0
  echo "  nothing to scrub: $SHORT is at or after the scrub commits"
else
  SCRUBBED=1
  SCRUB_FILES="$(cd "$RAW" && find . -type f | sed 's|^\./||' | sort | while IFS= read -r f; do
    cmp -s "$RAW/$f" "$EXPORT/$f" || echo "$f"
  done)"
  SCRUB_FILE_COUNT="$(echo "$SCRUB_FILES" | wc -l | tr -d ' ')"
  echo "  $SCRUB_TOTAL replacement(s) in $SCRUB_FILE_COUNT file(s)"
  echo "$SCRUB_FILES" | while IFS= read -r f; do
    printf '    %-58s %s changed line(s)\n' "$f" "$(scrub_diff "$f" | wc -l | tr -d ' ')"
  done

  # The property that makes publishing an old release worth doing: a reader can
  # build the published source and get the binary they downloaded. That holds
  # only while the scrub stays out of the compiled targets' behaviour, so every
  # scrubbed line under Sources/ and Fulcrum/ is classified here. A comment line
  # is one whose text begins with //, ///, /* or *; anything else is code, and
  # code is fatal.
  say "Classifying what the scrub changed under Sources/ and Fulcrum/"
  CODE_HITS=""
  APP_FILES="$(echo "$SCRUB_FILES" | grep -E '^(Sources|Fulcrum)/' || true)"
  if [ -z "$APP_FILES" ]; then
    echo "  the scrub did not touch a compiled target at all"
  else
    echo "$APP_FILES" | while IFS= read -r f; do
      printf '    %s\n' "$f"
      scrub_diff "$f" | cut -c1-140 | sed 's|^|      |'
    done
    # A line counts as a comment only if its own text starts one. `///` inside a
    # string literal would not qualify, which is the conservative direction: the
    # cost of misreading a comment as code is a needless abort, and the cost of
    # misreading code as a comment is publishing a false claim about a binary.
    #
    # The patterns are written with a LEADING `(`. bash 3.2 — the /bin/bash this
    # script must run under — parses `$( … )` by scanning for a balancing paren
    # and counts the one that closes a case pattern, so a bare `//*)` ends the
    # substitution early. It fails as `l: unbound variable`, which names neither
    # the case statement nor the substitution. Opening the pattern balances it.
    CODE_HITS="$(echo "$APP_FILES" | while IFS= read -r f; do
      scrub_diff "$f" | sed 's|^[<>] *||' | while IFS= read -r l; do
        case "$l" in
          (//*|/\**|\**) ;;
          (*) echo "$f: $l" ;;
        esac
      done
    done)"
    if [ -n "$CODE_HITS" ]; then
      printf '\n\033[31m  NOT a comment — the scrub changes what a compiled target contains:\033[0m\n'
      echo "$CODE_HITS" | cut -c1-160 | sed 's|^|    |'
      if [ "$ALLOW_CODE_SCRUB" -eq 0 ]; then
        fail "the scrub rewrites code, not just comments, in a compiled target.
  Source published this way does NOT build the binary that shipped, so a reader
  who checks cannot reproduce the DMG. Decide what to publish before publishing
  it: withdraw the release from the public repo, or accept the divergence and
  re-run with --allow-code-scrub, which states it in the public commit message."
      fi
      printf '\n\033[33m  --allow-code-scrub given: publishing anyway, and saying so in the commit.\033[0m\n'
    else
      echo
      echo "  comment-only: every scrubbed line in a compiled target is a comment"
    fi
  fi
fi

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
[ "$FRESH" -eq 1 ] && echo "  history: RESTARTED — this becomes the root commit of $BRANCH"
[ "$SCRUBBED" -eq 1 ] && echo "  scrub:   $SCRUB_TOTAL replacement(s); the public tree is NOT the private tree"
[ ${#GRAFTED_PATHS[@]} -gt 0 ] && echo "  graft:   ${GRAFTED_PATHS[*]} from $GRAFT_SHORT"
echo
(cd "$EXPORT" && find . -type f | sed 's|^\./||' | sort | awk '{print "    " $0}')

# The commit message is assembled from what actually happened, not from a
# template with the interesting part written in by hand. A scrubbed export that
# claimed to be the private tree would be a lie told permanently, in public, by
# the one script whose whole job is not to do that.
MESSAGE="Fulcrum $VERSION

Source-only snapshot, published by scripts/publish-source.sh.

Produced from $COMMIT in the private repository, which holds the full
history. This repository carries one squashed commit per release, so its
history does not correspond to that one commit for commit; the sha above is
the way back to the internal history of this release."

if [ ${#ABSENT_PATHS[@]} -gt 0 ]; then
  MESSAGE="$MESSAGE

Not present at that commit, and so not in this snapshot: $(echo "${ABSENT_PATHS[*]}" | sed 's/ /, /g')."
fi

if [ ${#GRAFTED_PATHS[@]} -gt 0 ]; then
  MESSAGE="$MESSAGE

$(echo "${GRAFTED_PATHS[*]}" | sed 's/ /, /g') are NOT from $SHORT. They did not exist yet at
that commit; they are taken from $GRAFT_SHORT, and they are the only files in
this snapshot not derived from the sha above.

That is deliberate. A tag whose tree carries no licence hands a reader source
with no grant of rights, which is not a thing to publish on purpose in a
repository that exists to take issues and pull requests. Read the README as
describing the project rather than as describing this tag: it is the later
commit's README, and it can name work that came after this release."
  if [ -n "$GRAFT_NOTE" ]; then
    # Wrapped here rather than by whoever typed it: a note passed on a command
    # line arrives as one long line, and a git log full of 200-column paragraphs
    # is a git log nobody reads.
    MESSAGE="$MESSAGE

$(printf '%s\n' "$GRAFT_NOTE" | fold -s -w 76 | sed 's/[[:space:]]*$//')"
  fi
fi

if [ "$SCRUBBED" -eq 1 ]; then
  MESSAGE="$MESSAGE

This tree is NOT byte-identical to $SHORT. That commit predates the two
commits that renamed the developer's employer's systems out of the fixtures
and comments, and rewriting tagged private history to fix it would invalidate
the release tag that records what shipped. The renames are therefore replayed
onto this export at publish time, from the table in scripts/publish-source.sh —
$SCRUB_TOTAL replacements across $SCRUB_FILE_COUNT files. Each one substitutes a
fictional name (northwind, contoso, /Users/dev) for a real one, or rewrites a
comment whose claim the substitution would otherwise have falsified."
  if [ -n "$CODE_HITS" ]; then
    MESSAGE="$MESSAGE

Some of those replacements are in code rather than in comments, so the sources
here do NOT compile byte-for-byte to the signed binary distributed for this
release. The changed literals are names in test fixtures and error samples;
they do not change behaviour, but a reader reproducing the build should expect
a different hash."
  else
    MESSAGE="$MESSAGE

Under Sources/ and Fulcrum/ the scrub changed comments only, so this source
still compiles to the binary that was signed, notarized and distributed for
this release. Everything else it changed is a test fixture."
  fi
fi

if [ "$PUSH" -eq 0 ]; then
  say "The commit message this would carry"
  echo "$MESSAGE" | sed 's|^|    |'
  say "Dry run — nothing was pushed"
  echo "  This run reached the network not at all."
  printf '  Publish with:  scripts/publish-source.sh%s --version %s%s%s%s --push\n' \
    "${FROM:+ --from $FROM}" "$VERSION" \
    "$([ "$FRESH" -eq 1 ] && echo ' --fresh')" \
    "$([ -n "$CODE_HITS" ] && echo ' --allow-code-scrub')" \
    "${GRAFT_FROM:+ --graft-from $GRAFT_FROM}"
  [ -n "$GRAFT_NOTE" ] && echo "                 …plus the --graft-note you passed."
  exit 0
fi

# ---------------------------------------------------------------------------
# Past this point the operation is irreversible.
# ---------------------------------------------------------------------------
say "Publishing to $REMOTE"

# --fresh discards the public branch and every release tag on it. That is what
# rebuilding the history in release order requires — the first snapshot has to
# become a ROOT commit, and the tags of the history being replaced would
# otherwise collide with the ones about to be created. It is listed before the
# confirmation prompt, by name, read from the remote: "force push" is easy to
# agree to in the abstract and specific when it names the tags it deletes.
DOOMED_TAGS=""
if [ "$FRESH" -eq 1 ]; then
  DOOMED_TAGS="$(git ls-remote --tags "$REMOTE" 'refs/tags/v*' 2>/dev/null \
    | sed 's|.*refs/tags/||; s|\^{}$||' | sort -u || true)"
  printf '\n\033[31m  --fresh: %s is replaced, not appended to.\033[0m\n' "$BRANCH"
  echo "  Its existing commits stop being reachable, and these tags are deleted:"
  if [ -n "$DOOMED_TAGS" ]; then
    echo "$DOOMED_TAGS" | sed 's|^|    |'
  else
    echo "    (none)"
  fi
  echo "  Public git is mirrored: this hides the old history, it does not unpublish it."
fi

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
if [ "$FRESH" -eq 1 ]; then
  # Deliberately NOT cloned. Cloning and then committing on top would make this
  # snapshot a child of the history it is meant to replace, and the old tree
  # would stay reachable from the new commit's parent.
  git init -q "$PUBLIC"
  git -C "$PUBLIC" remote add origin "$REMOTE"
  git -C "$PUBLIC" checkout -q -B "$BRANCH"
  echo "  starting $BRANCH from nothing"
else
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

  # Asked of the REMOTE, not of the shallow clone: `clone --depth 1` brings down
  # only the tags reachable from the tip it fetched, so a tag left behind by a
  # withdrawn release is exactly the one a local check would miss.
  if git ls-remote --tags "$REMOTE" "refs/tags/v$VERSION" 2>/dev/null | grep -q .; then
    fail "v$VERSION is already published — bump the version, or delete that tag if the release was withdrawn"
  fi
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
TAG_MESSAGE="Fulcrum $VERSION (from $SHORT)"
[ "$SCRUBBED" -eq 1 ] && TAG_MESSAGE="$TAG_MESSAGE
Scrubbed at export: see the commit message for what differs from $SHORT."
git -C "$PUBLIC" tag -a "v$VERSION" -m "$TAG_MESSAGE"

if [ "$FRESH" -eq 1 ]; then
  # Tags first, and deleted before the branch moves: a tag left pointing into
  # the discarded history keeps it reachable, which is the whole thing --fresh
  # is for. Deleting one that is already gone is not an error worth stopping on.
  if [ -n "$DOOMED_TAGS" ]; then
    echo "$DOOMED_TAGS" | while IFS= read -r t; do
      git -C "$PUBLIC" push -q origin ":refs/tags/$t" 2>/dev/null || true
      echo "  deleted tag $t"
    done
  fi
  git -C "$PUBLIC" push -q --force origin "$BRANCH" || fail "push rejected"
else
  git -C "$PUBLIC" push -q origin "$BRANCH" || fail "push rejected"
fi
git -C "$PUBLIC" push -q origin "v$VERSION" || fail "tag push rejected"

say "Published"
echo "  $REMOTE  $BRANCH  v$VERSION"
echo "  public commit $(git -C "$PUBLIC" rev-parse --short HEAD) = private $SHORT"
[ "$SCRUBBED" -eq 1 ] && echo "  scrubbed at export: $SCRUB_TOTAL replacement(s), recorded in the commit message"
exit 0
