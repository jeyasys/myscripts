#!/usr/bin/env bash
# WordPress DB backup: charset detect, strict space check (no prompt), progress, safe writes
# Conditional post-processing (with confirmation):
#  - utf8mb4_0900_ai_ci -> utf8mb4_unicode_ci  (only if present)
#  - DEFINER=`user`@`host` -> CURRENT_USER and SQL SECURITY DEFINER -> INVOKER (only if present)
set -Eeuo pipefail

# ---------- Self-delete on exit ----------
SELF_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
cleanup_self() { echo "Deleting script: $SELF_PATH"; rm -f -- "$SELF_PATH" >/dev/null 2>&1 || true; }
trap cleanup_self EXIT

# ---------- Styling ----------
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%F %T')]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------- Preconditions ----------
if [[ ! -f ./wp-config.php ]]; then
  err "Run this from /var/www/webroot/ROOT (wp-config.php not found)."
  exit 1
fi

WP="${WP:-wp}"  # override via WP=/path/to/wp if needed

# Temp error capture; we only persist it if an error happens.
TMP_ERR="$(mktemp -t dbdump_err.XXXXXX)"
cleanup_tmp_err() { rm -f "$TMP_ERR" >/dev/null 2>&1 || true; }
# don't trap here; we'll delete it on success paths.

# ---------- 1) Charset via WP-CLI ----------
DB_CHARSET="$($WP eval 'global $wpdb; echo $wpdb->charset . PHP_EOL;' --allow-root --skip-plugins --skip-themes 2>>"$TMP_ERR" | tr -d '\r\n' || true)"
DB_CHARSET="${DB_CHARSET:-utf8mb4}"
info "Detected DB charset: ${DB_CHARSET}"

# ---------- 2) Parse DB creds ----------
extract_define() {
  local key="$1"
  grep -E "define\(\s*['\"]${key}['\"]" wp-config.php \
    | sed -E "s/.*define\(\s*['\"]${key}['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/" \
    | tr -d '\r' | head -n1
}
DB_NAME=$(extract_define "DB_NAME")
DB_USER=$(extract_define "DB_USER")
DB_PASSWORD=$(extract_define "DB_PASSWORD")
DB_HOST=$(extract_define "DB_HOST")
if [[ -z "${DB_NAME:-}" || -z "${DB_USER:-}" || -z "${DB_HOST:-}" ]]; then
  err "Could not read DB credentials from wp-config.php"
  mv -f "$TMP_ERR" backup_db.err.log 2>/dev/null || true
  echo "Error details saved to $(pwd)/backup_db.err.log"
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
OUT_FINAL="${DB_NAME}_${STAMP}.sql"
OUT_TMP="${OUT_FINAL}.tmp.$$"

# Keep partial on failure/interruption (so you can inspect), but never claim final name.
cleanup_partials() {
  if [[ -f "$OUT_TMP" ]]; then
    warn "Leaving partial dump: ${OUT_FINAL}.partial.$(date +%s)"
    mv -f "$OUT_TMP" "${OUT_FINAL}.partial.$(date +%s)" 2>/dev/null || rm -f "$OUT_TMP" || true
  fi
}
trap cleanup_partials INT TERM ERR

# ---------- 3) Host/port/socket ----------
HOST_OPT=""; PORT_OPT=""; SOCKET_OPT=""
if [[ "$DB_HOST" == /* ]]; then
  SOCKET_OPT="--socket=$DB_HOST"
elif [[ "$DB_HOST" == *":"* ]]; then
  host_part="${DB_HOST%%:*}"
  rest="${DB_HOST#*:}"
  if [[ "$rest" =~ ^[0-9]+$ ]]; then
    HOST_OPT="--host=$host_part"; PORT_OPT="--port=$rest"
  elif [[ "$rest" == /* ]]; then
    SOCKET_OPT="--socket=$rest"
  else
    HOST_OPT="--host=$DB_HOST"
  fi
else
  HOST_OPT="--host=$DB_HOST"
fi

# ---------- 4) Optional capability flags ----------
GTID_ARG=""; COLSTAT_ARG=""
mysqldump --help 2>/dev/null | grep -q -- "--set-gtid-purged"   && GTID_ARG="--set-gtid-purged=OFF"
mysqldump --help 2>/dev/null | grep -q -- "--column-statistics" && COLSTAT_ARG="--column-statistics=0"

# ---------- 5) EXACT base args ----------
BASE_ARGS=(
  --user="$DB_USER"
  --default-character-set="${DB_CHARSET:-utf8mb4}"
  --single-transaction
  --quick
  --hex-blob
  --skip-lock-tables
  --triggers
  --routines
  --events
  --max-allowed-packet=512M
  --net-buffer-length=1048576
  --add-drop-table
  --skip-comments
  --no-tablespaces
)
[[ -n "$HOST_OPT"    ]] && BASE_ARGS+=("$HOST_OPT")
[[ -n "$PORT_OPT"    ]] && BASE_ARGS+=("$PORT_OPT")
[[ -n "$SOCKET_OPT"  ]] && BASE_ARGS+=("$SOCKET_OPT")
[[ -n "$GTID_ARG"    ]] && BASE_ARGS+=("$GTID_ARG")
[[ -n "$COLSTAT_ARG" ]] && BASE_ARGS+=("$COLSTAT_ARG")

# ---------- 6) Space analysis (strict, no prompt) ----------
# Estimate DB size (bytes); default 2 GiB if unknown
EST_DB_BYTES="$($WP db size --allow-root --skip-plugins --skip-themes --quiet --size_format=b 2>>"$TMP_ERR" | grep -Eo '^[0-9]+' || true)"
EST_DB_BYTES="${EST_DB_BYTES:-2147483648}"
REQUIRED_BYTES=$(( (EST_DB_BYTES * 110) / 100 )) # +10% buffer
AVAIL_BYTES=$(df -B1 . | awk 'NR==2{print $4}')

echo
info "=== Disk Space Analysis ==="
echo "Estimated dump size:          $(numfmt --to=iec $EST_DB_BYTES)"
echo "Required (with 10% buffer):   $(numfmt --to=iec $REQUIRED_BYTES)"
echo "Available on target FS:       $(numfmt --to=iec $AVAIL_BYTES)"
echo

if (( AVAIL_BYTES < REQUIRED_BYTES )); then
  err "Insufficient space for DB backup. Aborting."
  mv -f "$TMP_ERR" backup_db.err.log 2>/dev/null || true
  echo "Details (if any) saved to $(pwd)/backup_db.err.log"
  exit 1
fi
# Enough space -> proceed immediately (no prompt)

# ---------- 7) Dump with progress & safe write ----------
log "Exporting database to $OUT_FINAL …"
if command -v pv >/dev/null 2>&1; then
  set +e
  MYSQL_PWD="$DB_PASSWORD" mysqldump "${BASE_ARGS[@]}" "$DB_NAME" 2>>"$TMP_ERR" \
    | pv -s "$EST_DB_BYTES" > "$OUT_TMP"
  DUMP_STATUS=${PIPESTATUS[0]}
  set -e
else
  warn "pv not found; showing basic progress (bytes written)…"
  set +e
  ( MYSQL_PWD="$DB_PASSWORD" mysqldump "${BASE_ARGS[@]}" "$DB_NAME" > "$OUT_TMP" 2>>"$TMP_ERR" ) &
  PID=$!
  while kill -0 "$PID" 2>/dev/null; do
    if [[ -f "$OUT_TMP" ]]; then
      CUR=$(stat -c%s "$OUT_TMP" 2>/dev/null || echo 0)
      printf "\r${BLUE}[INFO]${NC} Written: %s" "$(numfmt --to=iec $CUR)"
    fi
    sleep 2
  done
  wait "$PID"; DUMP_STATUS=$?
  set -e
  echo
fi

# Retry without routines/events if needed
if [[ $DUMP_STATUS -ne 0 || ! -s "$OUT_TMP" ]]; then
  warn "Initial dump failed. Retrying without routines/events…"
  SAFE_ARGS=(
    --user="$DB_USER"
    --default-character-set="${DB_CHARSET:-utf8mb4}"
    --single-transaction
    --quick
    --hex-blob
    --skip-lock-tables
    --triggers
    --max-allowed-packet=512M
    --net-buffer-length=1048576
    --add-drop-table
    --skip-comments
    --no-tablespaces
  )
  [[ -n "$HOST_OPT"    ]] && SAFE_ARGS+=("$HOST_OPT")
  [[ -n "$PORT_OPT"    ]] && SAFE_ARGS+=("$PORT_OPT")
  [[ -n "$SOCKET_OPT"  ]] && SAFE_ARGS+=("$SOCKET_OPT")
  [[ -n "$COLSTAT_ARG" ]] && SAFE_ARGS+=("$COLSTAT_ARG")

  : > "$OUT_TMP"
  if command -v pv >/dev/null 2>&1; then
    set +e
    MYSQL_PWD="$DB_PASSWORD" mysqldump "${SAFE_ARGS[@]}" "$DB_NAME" 2>>"$TMP_ERR" \
      | pv -s "$EST_DB_BYTES" > "$OUT_TMP"
    DUMP_STATUS=${PIPESTATUS[0]}
    set -e
  else
    set +e
    ( MYSQL_PWD="$DB_PASSWORD" mysqldump "${SAFE_ARGS[@]}" "$DB_NAME" > "$OUT_TMP" 2>>"$TMP_ERR" ) &
    PID=$!
    while kill -0 "$PID" 2>/dev/null; do
      if [[ -f "$OUT_TMP" ]]; then
        CUR=$(stat -c%s "$OUT_TMP" 2>/dev/null || echo 0)
        printf "\r${BLUE}[INFO]${NC} Written: %s" "$(numfmt --to=iec $CUR)"
      fi
      sleep 2
    done
    wait "$PID"; DUMP_STATUS=$?
    set -e
    echo
  fi
fi

if [[ $DUMP_STATUS -ne 0 || ! -s "$OUT_TMP" ]]; then
  err "Database export failed."
  mv -f "$TMP_ERR" backup_db.err.log 2>/dev/null || true
  echo "Error details saved to $(pwd)/backup_db.err.log"
  exit 1
fi

# ---------- 8) Conditional fixes (with confirmation) ----------
NEED_COLLATION_FIX="no"
NEED_DEFINER_FIX="no"
grep -m1 -q 'utf8mb4_0900_ai_ci' "$OUT_TMP" && NEED_COLLATION_FIX="yes" || true
grep -m1 -E -q 'DEFINER=`[^`]+`@`[^`]+`|SQL SECURITY DEFINER' "$OUT_TMP" && NEED_DEFINER_FIX="yes" || true

if [[ "$NEED_COLLATION_FIX" == "yes" || "$NEED_DEFINER_FIX" == "yes" ]]; then
  echo
  info "=== Post-processing candidates detected ==="
  if [[ "$NEED_COLLATION_FIX" == "yes" ]]; then
    CCOUNT=$(grep -o 'utf8mb4_0900_ai_ci' "$OUT_TMP" | wc -l || echo 0)
    echo "  Collation: utf8mb4_0900_ai_ci -> utf8mb4_unicode_ci  (matches: $CCOUNT)"
  fi
  if [[ "$NEED_DEFINER_FIX" == "yes" ]]; then
    DCOUNT=$(grep -E -o 'DEFINER=`[^`]+`@`[^`]+`' "$OUT_TMP" | wc -l || echo 0)
    SCOUNT=$(grep -E -o 'SQL SECURITY DEFINER' "$OUT_TMP" | wc -l || echo 0)
    echo "  DEFINERs : DEFINER=… -> CURRENT_USER                 (matches: $DCOUNT)"
    echo "  Security : SQL SECURITY DEFINER -> INVOKER           (matches: $SCOUNT)"
  fi
  echo
  read -r -p "Apply these fixes carefully? (Y/n): " fix_ans
  fix_ans=${fix_ans:-Y}

  if [[ "$fix_ans" =~ ^[Yy]$ ]]; then
    OUT_PROC="${OUT_FINAL}.proc.tmp.$$"
    # ensure any failure still keeps partial processed output
    trap '[[ -f "$OUT_PROC" ]] && mv -f "$OUT_PROC" "${OUT_FINAL}.partial.$(date +%s).proc" 2>/dev/null || true' INT TERM ERR

    info "Applying fixes (streaming)…"
    if command -v pv >/dev/null 2>&1; then
      SED_PROG=()
      [[ "$NEED_DEFINER_FIX" == "yes" ]] && SED_PROG+=(-e 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' -e 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g')
      [[ "$NEED_COLLATION_FIX" == "yes" ]] && SED_PROG+=(-e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g')

      set +e
      pv -s "$(stat -c%s "$OUT_TMP")" "$OUT_TMP" \
        | sed -E "${SED_PROG[@]}" > "$OUT_PROC" 2>>"$TMP_ERR"
      PROC_STATUS=${PIPESTATUS[1]}
      set -e
    else
      SED_PROG_FILE="$(mktemp -t sedprog.XXXXXX)"
      {
        [[ "$NEED_DEFINER_FIX" == "yes" ]] && echo 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g'
        [[ "$NEED_DEFINER_FIX" == "yes" ]] && echo 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g'
        [[ "$NEED_COLLATION_FIX" == "yes" ]] && echo 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
      } > "$SED_PROG_FILE"

      set +e
      ( sed -E -f "$SED_PROG_FILE" "$OUT_TMP" > "$OUT_PROC" 2>>"$TMP_ERR" ) &
      PIDP=$!
      while kill -0 "$PIDP" 2>/dev/null; do
        if [[ -f "$OUT_PROC" ]]; then
          CUR=$(stat -c%s "$OUT_PROC" 2>/dev/null || echo 0)
          printf "\r${BLUE}[INFO]${NC} Written: %s" "$(numfmt --to=iec $CUR)"
        fi
        sleep 2
      done
      wait "$PIDP"; PROC_STATUS=$?
      set -e
      rm -f "$SED_PROG_FILE" || true
      echo
    fi

    if [[ ${PROC_STATUS:-0} -ne 0 || ! -s "$OUT_PROC" ]]; then
      err "Post-processing failed."
      mv -f "$TMP_ERR" backup_db.err.log 2>/dev/null || true
      echo "Error details saved to $(pwd)/backup_db.err.log"
      exit 1
    fi

    mv -f "$OUT_PROC" "$OUT_FINAL"
    rm -f "$OUT_TMP" || true
  else
    info "Skipping fixes; keeping raw dump."
    mv -f "$OUT_TMP" "$OUT_FINAL"
  fi
else
  mv -f "$OUT_TMP" "$OUT_FINAL"
fi

# Success → remove temp err capture if empty; else persist as warning
if [[ -s "$TMP_ERR" ]]; then
  # Only persist if a *real* error happened earlier; by now success, so drop it
  rm -f "$TMP_ERR" >/dev/null 2>&1 || true
else
  rm -f "$TMP_ERR" >/dev/null 2>&1 || true
fi

SIZE=$(stat -c%s "$OUT_FINAL" 2>/dev/null || echo 0)
SHA=$(sha256sum "$OUT_FINAL" | awk '{print $1}')

echo
log "Database backup completed."
echo -e "${BLUE}Summary:${NC}"
echo "  Output: $(pwd)/$OUT_FINAL"
echo "  Size:   $(numfmt --to=iec $SIZE)"
echo "  Charset used: ${DB_CHARSET}"
echo "  SHA256: $SHA"
