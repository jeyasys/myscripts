#!/usr/bin/env bash
# WordPress files backup with excludes, space check, progress, safe writes
# No log file unless an error occurs. Self-delete only on success or explicit abort.
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
  err "Please run this script from /var/www/webroot (must contain ./ROOT and ./ROOT/wp-config.php)."
  exit 1
fi

OUT_FINAL="ROOT.tar.gz"
OUT_TMP="${OUT_FINAL}.tmp.$$"

# Capture stderr to a temp file; only persist it if an error actually happens
TMP_ERR="$(mktemp -t files_backup_err.XXXXXX)"
cleanup_tmp() { rm -f "$TMP_ERR" >/dev/null 2>&1 || true; }
# Keep partial archives on unexpected errors so you can inspect them
cleanup_partial_on_err() {
  if [[ -f "$OUT_TMP" ]]; then
    warn "Keeping partial archive as ${OUT_FINAL}.partial.$(date +%s)"
    mv -f "$OUT_TMP" "${OUT_FINAL}.partial.$(date +%s)" 2>/dev/null || rm -f "$OUT_TMP" || true
  fi
}
trap cleanup_partial_on_err INT TERM ERR

# ---------- Excludes (matches your manager’s defaults) ----------
read -r -d '' EXCLUDES <<'EOF'
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
EOF

# ---------- Space analysis ----------
WP_BYTES=$(du -sb ROOT 2>/dev/null | awk '{print $1}')
AVAIL_BYTES=$(df -B1 . | awk 'NR==2{print $4}')
REQUIRED_BYTES=$(( (WP_BYTES * 110) / 100 ))  # +10% buffer

echo
info "=== Disk Space Analysis ==="
echo "WordPress dir size:           $(numfmt --to=iec "$WP_BYTES")"
echo "Required (with 10% buffer):   $(numfmt --to=iec "$REQUIRED_BYTES")"
echo "Available on target FS:       $(numfmt --to=iec "$AVAIL_BYTES")"
# Rough estimate (informational) for gzip compression ~60%
EST_GZ_BYTES=$(( (WP_BYTES * 60) / 100 ))
echo "Estimated .tar.gz size (~60%): $(numfmt --to=iec "$EST_GZ_BYTES")"
echo

# If insufficient space, abort cleanly and self-delete
if (( AVAIL_BYTES < REQUIRED_BYTES )); then
  err "Insufficient free space to safely create archive. Aborting."
  # Persist error details if any exist
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
if command -v pv >/dev/null 2>&1; then
  info "Using pv for progress…"
  set +e
  tar -cpf - --acls --xattrs --numeric-owner ${EXCLUDES} ROOT 2>>"$TMP_ERR" \
    | pv -s "$WP_BYTES" \
    | gzip -9 > "$OUT_TMP"
  TAR_STATUS=${PIPESTATUS[0]}
  GZ_STATUS=${PIPESTATUS[2]}
  set -e
else
  warn "pv not found; showing basic progress (bytes written)…"
  set +e
  ( tar -cpf - --acls --xattrs --numeric-owner ${EXCLUDES} ROOT 2>>"$TMP_ERR" \
    | gzip -9 > "$OUT_TMP" ) &
  PIPE_PID=$!
  while kill -0 "$PIPE_PID" 2>/dev/null; do
    if [[ -f "$OUT_TMP" ]]; then
      CUR=$(stat -c%s "$OUT_TMP" 2>/dev/null || echo 0)
      printf "\r${BLUE}[INFO]${NC} Written: %s" "$(numfmt --to=iec "$CUR")"
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
if [[ ${TAR_STATUS:-0} -ne 0 || ${GZ_STATUS:-0} -ne 0 || ! -s "$OUT_TMP" ]]; then
  err "Archive creation failed."
  if [[ -s "$TMP_ERR" ]]; then
    mv -f "$TMP_ERR" backup_files.err.log 2>/dev/null || true
    echo "Error details saved to $(pwd)/backup_files.err.log"
  else
    cleanup_tmp
  fi
  exit 1  # (self-delete NOT triggered on generic failure; keeps script for rerun)
fi

mv -f "$OUT_TMP" "$OUT_FINAL"
SIZE=$(stat -c%s "$OUT_FINAL" 2>/dev/null || echo 0)
SHA=$(sha256sum "$OUT_FINAL" | awk '{print $1}')

# No errors → remove temp err capture silently
cleanup_tmp

echo
log "Files backup completed."
echo -e "${BLUE}Summary:${NC}"
echo "  Output: $(pwd)/$OUT_FINAL"
echo "  Size:   $(numfmt --to=iec "$SIZE")"
echo "  SHA256: $SHA"

# Success → self-delete
self_delete
