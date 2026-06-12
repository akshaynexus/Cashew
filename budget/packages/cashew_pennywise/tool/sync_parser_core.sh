#!/usr/bin/env bash
#
# sync_parser_core.sh
# --------------------
# Vendors PennyWise's pure-Kotlin `parser-core` (the 120-bank SMS parser) into
# this plugin's Android source set, plus the `shared/` GPay+PhonePe statement
# parsers as a read-only reference for the Dart PDF port.
#
# The SMS parser is NEVER reimplemented in Dart — it is compiled, as-is, into the
# plugin AAR and called over a MethodChannel. Re-run this script to pull upstream
# parser updates: bump REF in tool/parser_core.lock (or pass --ref <sha>) and run.
#
# Usage:
#   tool/sync_parser_core.sh                 # use REPO_URL/REF from parser_core.lock
#   tool/sync_parser_core.sh --ref <sha>     # override the pinned ref
#   tool/sync_parser_core.sh --repo <url> --ref <sha>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$SCRIPT_DIR")"
LOCK_FILE="$SCRIPT_DIR/parser_core.lock"

# ---- Resolve repo + ref ------------------------------------------------------
REPO_URL=""
REF=""
# Read the lock file directly (no `source <(...)` — buggy on macOS bash 3.2).
if [ -f "$LOCK_FILE" ]; then
  while IFS='=' read -r key val; do
    case "$key" in
      REPO_URL) REPO_URL="$val" ;;
      REF) REF="$val" ;;
    esac
  done < "$LOCK_FILE"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2 ;;
    --ref)  REF="$2";      shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_URL" ] || [ -z "$REF" ]; then
  echo "ERROR: REPO_URL and REF must be set (in $LOCK_FILE or via --repo/--ref)." >&2
  exit 1
fi

echo "==> Vendoring parser-core"
echo "    repo: $REPO_URL"
echo "    ref:  $REF"

# ---- Sparse, shallow fetch of only the paths we need -------------------------
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PARSER_SUBDIR="parser-core/src"
PDF_REF_SUBDIR="shared/src/commonMain/kotlin/com/pennywiseai/shared/data/statement"

git -C "$TMP_DIR" init -q
git -C "$TMP_DIR" remote add origin "$REPO_URL"
git -C "$TMP_DIR" sparse-checkout init --cone
git -C "$TMP_DIR" sparse-checkout set "$PARSER_SUBDIR" "$PDF_REF_SUBDIR"

# GitHub allows fetching an arbitrary reachable commit SHA directly.
if ! git -C "$TMP_DIR" fetch -q --depth 1 origin "$REF" 2>/dev/null; then
  echo "    (direct SHA fetch unavailable; falling back to full shallow fetch)"
  git -C "$TMP_DIR" fetch -q --depth 50 origin
fi
git -C "$TMP_DIR" checkout -q "$REF"
RESOLVED_SHA="$(git -C "$TMP_DIR" rev-parse HEAD)"

# ---- Copy parser-core (commonMain + jvmMain) into one compiled srcDir --------
# Both live under the same package root (com/pennywiseai/parser/core) with no
# file overlap, so they merge into a single Kotlin source directory.
DEST_PARSER="$PKG_DIR/android/vendor/parser-core/kotlin"
rm -rf "$PKG_DIR/android/vendor/parser-core"
mkdir -p "$DEST_PARSER"
cp -R "$TMP_DIR/parser-core/src/main/kotlin/." "$DEST_PARSER/"
cp -R "$TMP_DIR/parser-core/src/commonMain/kotlin/." "$DEST_PARSER/"

# ---- Copy GPay/PhonePe statement parsers as a Dart-port reference (not built) -
DEST_REF="$PKG_DIR/tool/reference/statement"
rm -rf "$PKG_DIR/tool/reference"
mkdir -p "$DEST_REF"
cp -R "$TMP_DIR/$PDF_REF_SUBDIR/." "$DEST_REF/"

# ---- Stamp the resolved SHA back into the lock file --------------------------
{
  echo "# Pinned source for the vendored PennyWise parser-core."
  echo "# Edit REF and re-run tool/sync_parser_core.sh to update the parser."
  echo "REPO_URL=$REPO_URL"
  echo "REF=$RESOLVED_SHA"
} > "$LOCK_FILE"

KT_COUNT="$(find "$DEST_PARSER" -name '*.kt' | wc -l | tr -d ' ')"
REF_COUNT="$(find "$DEST_REF" -name '*.kt' | wc -l | tr -d ' ')"
echo "==> Done."
echo "    parser-core: $KT_COUNT Kotlin files -> android/vendor/parser-core/kotlin"
echo "    pdf reference: $REF_COUNT Kotlin files -> tool/reference/statement"
echo "    locked at $RESOLVED_SHA"
