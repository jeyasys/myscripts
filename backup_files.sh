#!/usr/bin/env bash
# WordPress files backup (gzip), excludes, progress, safe write, quick verification.
# No log file unless there’s an error. Self-delete on success or space-abort.
set -Eeuo pipefail

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

# ---------- Excludes ----------
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

# Build a corresponding find(1) prune expression for verification counting
# (we only exclude directories/prefix-es we know; glob file patterns are handled with -path)
build_find_prunes() {
  local args=()
  local pat
  for pat in "${EXCLUDES[@]}"; do
    pat="${pat#--exclude=}"
    # find expects paths without leading ./, our tree is ROOT/...
    # Use -path 'pattern' -prune -o for both dirs and file globs.
    args+=( -path "$pat" -prune -o )
  done
  printf '%s\n' "${args[@]}"
}

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
    | gzip -9 > "$OUT_TMP"
  # Capture statuses immediately (guard for set -u)
  _ps=("${PIPESTATUS[@]:-}")
  TAR_STATUS="${_ps[0]:-1}"
  GZ_STATUS="${_ps[2]:-1}"
  unset _ps
  set -e
else
  # Fallback progress (bytes written)
  set +e
  ( tar -cpf - --acls --xattrs --numeric-owner "${EXCLUDES[@]}" ROOT 2>>"$TMP_ERR" \
    | gzip -9 > "$OUT_TMP" ) &
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

# ---------- Quick verification ----------
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

# 3) Count source files (excluding patterns) vs files in archive
#    (files only; dirs not counted)
mapfile -t PRUNES < <(build_find_prunes)
# shellcheck disable=SC2068
SRC_FILE_COUNT=$(find ROOT \( ${PRUNES[@]} -false \) -type f -print 2>/dev/null | wc -l | tr -d ' ')
ARC_FILE_COUNT=$(tar -tzf "$OUT_FINAL" 2>/dev/null | grep -v '/$' | wc -l | tr -d ' ')

SIZE=$(stat -c%s "$OUT_FINAL" 2>/dev/null || echo 0)
SHA=$(sha256sum "$OUT_FINAL" | awk '{print $1}')

# No errors → remove temp err capture
cleanup_tmp

echo
log "Files backup completed."
echo -e "${BLUE}Summary:${NC}"
echo "  Output:           $(pwd)/$OUT_FINAL"
echo "  Archive size:     $(numfmt --to=iec "$SIZE")"
echo "  SHA256:           $SHA"
echo "  Source files:     $SRC_FILE_COUNT (after excludes)"
echo "  Archived files:   $ARC_FILE_COUNT"
if (( SRC_FILE_COUNT == ARC_FILE_COUNT )); then
  echo -e "  Match:            ${GREEN}YES${NC} (counts identical)"
else
  echo -e "  Match:            ${YELLOW}WARN${NC} (counts differ by $((SRC_FILE_COUNT-ARC_FILE_COUNT)))"
  echo "                     *Differences can occur if excludes matched files in find differently than tar*"
fi

# Success → self-delete
self_delete
