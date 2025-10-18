#!/usr/bin/env bash
# WordPress files backup (gzip), excludes, progress, safe write
# Quick verification by default; add --verify-deep for manifest comparison.
# No log file unless there’s an error. Self-delete on success or space-abort.
set -Eeuo pipefail

# ---------- CLI ----------
DEEP_VERIFY=0
if [[ "${1:-}" == "--verify-deep" ]]; then
  DEEP_VERIFY=1
fi

# ---------- Styling ----------
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%F %T')]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

SELF_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
self_delete() { echo "Deleting script: $SELF_PATH"; rm -f -- "$SELF_PATH" >/dev/null 2>&1 || true; }

# ---------- Preconditions ----------
if [[ ! -d ./ROOT || ! -f ./ROOT/wp-config.php ]]; then
  err "Please run from /var/www/webroot (must contain ./ROOT and ./ROOT/wp-config.php)."
  exit 1
fi

OUT_FINAL="ROOT.tar.gz"
OUT_TMP="${OUT_FINAL}.tmp.$$"

# Temp stderr capture; only persist if there’s an actual error
TMP_ERR="$(mktemp -t files_backup_err.XXXXXX)"
cleanup_tmp() { rm -f "$TMP_ERR" >/dev/null 2>&1 || true; }
cleanup_partial_on_err() {
  if [[ -f "$OUT_TMP" ]]; then
    warn "Keeping partial archive as ${OUT_FINAL}.partial.$(date +%s)"
    mv -f "$OUT_TMP" "${OUT_FINAL}.partial.$(date +%s)" 2>/dev/null || rm -f "$OUT_TMP" || true
  fi
}
trap cleanup_partial_on_err INT TERM ERR

# ---------- Excludes (kept identical to your manager’s set, rooted at ROOT/) ----------
EXCLUDES=(
  --exclude=ROOT/wp-content/ai1wm-backups
  --exclude=ROOT/wp-content/backups
  --exclude=ROOT/wp-content/backups-dup-pro
  --exclude=ROOT/wp-content/updraft
  --exclude=ROOT/wp-content/uploads/backup-*
  --exclude=ROOT/wp-content/uploads/backwpup-*
  --exclude=ROOT/wp-content/cache
  --exclude=ROOT/wp-content/uploads/cache
  --exclude=ROOT/wp-content/w3tc-cache
  --exclude=ROOT/wp-content/wp-rocket-cache
  --exclude=ROOT/wp-content/litespeed
  --exclude=ROOT/wp-content/debug.log
  --exclude=ROOT/wp-content/error_log
  --exclude=ROOT/wp-content/ewww
  --exclude=ROOT/wp-content/smush-webp
  --exclude=ROOT/wp-content/uploads/wp-file-manager-pro/fm_backup
  --exclude=ROOT/wp-config-backup.php
  --exclude=ROOT/error_log
  --exclude=*.log
)

# ---------- Space analysis ----------
WP_BYTES=$(du -sb ROOT 2>/dev/null | awk '{print $1}')
AVAIL_BYTES=$(df -B1 . | awk 'NR==2{print $4}')
REQUIRED_BYTES=$(( (WP_BYTES * 110) / 100 ))  # +10% buffer

echo
info "=== Disk Space Analysis ==="
echo "WordPress dir size:           $(numfmt --to=iec "$WP_BYTES")"
echo "Required (with 10% buffer):   $(numfmt --to=iec "$REQUIRED_BYTES")"
echo "Available on target FS:       $(numfmt --to=iec "$AVAIL_BYTES")"
EST_GZ_BYTES=$(( (WP_BYTES * 60) / 100 ))  # rough estimate for gzip
echo "Estimated .tar.gz size (~60%): $(numfmt --to=iec "$EST_GZ_BYTES")"
echo

# If insufficient space, abort cleanly and self-delete
if (( AVAIL_BYTES < REQUIRED_BYTES )); then
  err "Insufficient free space to safely create archive. Aborting."
  if [[ -s "$TMP_ERR" ]]; then
    mv -f "$TMP_ERR" backup_files.err.log 2>/dev/null || true
    echo "Error details saved to $(pwd)/backup_files.err.log"
  else
    cleanup_tmp
  fi
  self_delete
  exit 1
fi

# ---------- Create archive ----------
log "Creating archive at $(pwd)/$OUT_FINAL (gzip)…"
info "Progress…"

if command -v pv >/dev/null 2>&1; then
  # Use pv for progress; protect PIPESTATUS access with defaults to avoid 'unbound variable'
  set +e
  tar -cpf - --acls --xattrs --numeric-owner "${EXCLUDES[@]}" ROOT 2>>"$TMP_ERR" \
    | pv -s "$WP_BYTES" \
    | gzip -6 --rsyncable > "$OUT_TMP"
  _ps=("${PIPESTATUS[@]:-}")
  TAR_STATUS="${_ps[0]:-1}"
  GZ_STATUS="${_ps[2]:-1}"
  unset _ps
  set -e
else
  # Fallback progress (bytes written)
  set +e
  ( tar -cpf - --acls --xattrs --numeric-owner "${EXCLUDES[@]}" ROOT 2>>"$TMP_ERR" \
    | gzip -6 --rsyncable > "$OUT_TMP" ) &
  PIPE_PID=$!
  while kill -0 "$PIPE_PID" 2>/dev/null; do
    if [[ -f "$OUT_TMP" ]]; then
      CUR=$(stat -c%s "$OUT_TMP" 2>/dev/null || echo 0)
      printf "\r${BLUE}[INFO]${NC} Progress… %s" "$(numfmt --to=iec "$CUR")"
    fi
    sleep 2
  done
  wait "$PIPE_PID"; PIPE_STATUS=$?
  echo
  set -e
  TAR_STATUS=$PIPE_STATUS
  GZ_STATUS=$PIPE_STATUS
fi

# ---------- Handle result ----------
if [[ ${TAR_STATUS:-1} -ne 0 || ${GZ_STATUS:-1} -ne 0 || ! -s "$OUT_TMP" ]]; then
  err "Archive creation failed."
  if [[ -s "$TMP_ERR" ]]; then
    mv -f "$TMP_ERR" backup_files.err.log 2>/dev/null || true
    echo "Error details saved to $(pwd)/backup_files.err.log"
  else
    cleanup_tmp
  fi
  exit 1  # keep script for rerun/debug
fi

mv -f "$OUT_TMP" "$OUT_FINAL"

# ---------- Quick verification (fast) ----------
# 1) gzip integrity test
if ! gzip -t "$OUT_FINAL" 2>>"$TMP_ERR"; then
  err "gzip integrity test FAILED for $OUT_FINAL"
  if [[ -s "$TMP_ERR" ]]; then mv -f "$TMP_ERR" backup_files.err.log; echo "Details: $(pwd)/backup_files.err.log"; fi
  exit 1
fi

# 2) tar list test (ensures tar stream is readable)
if ! tar -tzf "$OUT_FINAL" > /dev/null 2>>"$TMP_ERR"; then
  err "tar readability test FAILED for $OUT_FINAL"
  if [[ -s "$TMP_ERR" ]]; then mv -f "$TMP_ERR" backup_files.err.log; echo "Details: $(pwd)/backup_files.err.log"; fi
  exit 1
fi

# 3) Count source files (files only; dirs not counted) using the SAME exclude semantics
SRC_FILE_COUNT=$(find ROOT \
  -path 'ROOT/wp-content/ai1wm-backups' -prune -o \
  -path 'ROOT/wp-content/backups' -prune -o \
  -path 'ROOT/wp-content/backups-dup-pro' -prune -o \
  -path 'ROOT/wp-content/updraft' -prune -o \
  -path 'ROOT/wp-content/uploads/backup-*' -prune -o \
  -path 'ROOT/wp-content/uploads/backwpup-*' -prune -o \
  -path 'ROOT/wp-content/cache' -prune -o \
  -path 'ROOT/wp-content/uploads/cache' -prune -o \
  -path 'ROOT/wp-content/w3tc-cache' -prune -o \
  -path 'ROOT/wp-content/wp-rocket-cache' -prune -o \
  -path 'ROOT/wp-content/litespeed' -prune -o \
  -path 'ROOT/wp-content/ewww' -prune -o \
  -path 'ROOT/wp-content/smush-webp' -prune -o \
  -path 'ROOT/wp-content/uploads/wp-file-manager-pro/fm_backup' -prune -o \
  -path 'ROOT/wp-config-backup.php' -prune -o \
  -path 'ROOT/error_log' -prune -o \
  -name '*.log' -prune -o \
  -type f -print 2>/dev/null | wc -l | tr -d ' ')

ARC_FILE_COUNT=$(tar -tzf "$OUT_FINAL" 2>/dev/null | grep -v '/$' | wc -l | tr -d ' ')
SIZE=$(stat -c%s "$OUT_FINAL" 2>/dev/null || echo 0)

echo
log "Files backup completed."
echo -e "${BLUE}Summary:${NC}"
echo "  Output:           $(pwd)/$OUT_FINAL"
echo "  Archive size:     $(numfmt --to=iec "$SIZE")"
echo "  Source files:     $SRC_FILE_COUNT (after excludes)"
echo "  Archived files:   $ARC_FILE_COUNT"
if (( SRC_FILE_COUNT == ARC_FILE_COUNT )); then
  echo -e "  Match:            ${GREEN}YES${NC} (counts identical)"
else
  echo -e "  Match:            ${YELLOW}WARN${NC} (counts differ by $((SRC_FILE_COUNT-ARC_FILE_COUNT)))"
  echo "                     *If this persists, a file was added/removed during the run or an exclude differs.*"
fi

# ---------- Deep verification (optional, slower) ----------
if (( DEEP_VERIFY == 1 )); then
  info "Running deep verification (manifests)…"
  SRC_MAN="source_manifest.txt"
  ARC_MAN="archive_manifest.txt"
  DIFF_MAN="manifest_diff.txt"

  # Source manifest: list files relative to repo root (ROOT/...), after excludes
  find ROOT \
    -path 'ROOT/wp-content/ai1wm-backups' -prune -o \
    -path 'ROOT/wp-content/backups' -prune -o \
    -path 'ROOT/wp-content/backups-dup-pro' -prune -o \
    -path 'ROOT/wp-content/updraft' -prune -o \
    -path 'ROOT/wp-content/uploads/backup-*' -prune -o \
    -path 'ROOT/wp-content/uploads/backwpup-*' -prune -o \
    -path 'ROOT/wp-content/cache' -prune -o \
    -path 'ROOT/wp-content/uploads/cache' -prune -o \
    -path 'ROOT/wp-content/w3tc-cache' -prune -o \
    -path 'ROOT/wp-content/wp-rocket-cache' -prune -o \
    -path 'ROOT/wp-content/litespeed' -prune -o \
    -path 'ROOT/wp-content/ewww' -prune -o \
    -path 'ROOT/wp-content/smush-webp' -prune -o \
    -path 'ROOT/wp-content/uploads/wp-file-manager-pro/fm_backup' -prune -o \
    -path 'ROOT/wp-config-backup.php' -prune -o \
    -path 'ROOT/error_log' -prune -o \
    -name '*.log' -prune -o \
    -type f -print 2>/dev/null \
    | LC_ALL=C sort > "$SRC_MAN"

  # Archive manifest: file paths as stored in the tar (also ROOT/…); ignore directories
  tar -tzf "$OUT_FINAL" 2>/dev/null | grep -v '/$' | LC_ALL=C sort > "$ARC_MAN"

  # Differences
  LC_ALL=C comm -3 "$SRC_MAN" "$ARC_MAN" > "$DIFF_MAN" || true

  SRC_MN=$(wc -l < "$SRC_MAN" | tr -d ' ')
  ARC_MN=$(wc -l < "$ARC_MAN" | tr -d ' ')
  DIFF_MN=$(wc -l < "$DIFF_MAN" | tr -d ' ')

  echo
  echo -e "${BLUE}Deep verification:${NC}"
  echo "  Source manifest:   $SRC_MN files  -> $SRC_MAN"
  echo "  Archive manifest:  $ARC_MN files  -> $ARC_MAN"
  if (( DIFF_MN == 0 )); then
    echo -e "  Diff:              ${GREEN}none${NC} (perfect match)"
    # optional: clean manifests if you prefer
    # rm -f "$SRC_MAN" "$ARC_MAN" "$DIFF_MAN"
  else
    echo -e "  Diff:              ${YELLOW}$DIFF_MN entries${NC} -> $DIFF_MAN (first 20 lines below)"
    sed -n '1,20p' "$DIFF_MAN"
  fi
fi

# No errors → remove temp err capture
cleanup_tmp

# Success → self-delete
self_delete
