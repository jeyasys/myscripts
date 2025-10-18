#!/usr/bin/env bash
# WordPress DB backup with charset detection, space check, prompt, progress, safe writes
# PLUS optional post-processing:
#  - Collation fix: utf8mb4_0900_ai_ci -> utf8mb4_unicode_ci (if present)
#  - DEFINER fix:   DEFINER=`user`@`host` -> DEFINER=CURRENT_USER
#                   SQL SECURITY DEFINER  -> SQL SECURITY INVOKER
set -Eeuo pipefail

# ============ Styling ============
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +'%F %T')]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ ! -f ./wp-config.php ]]; then
  err "Run this from /var/www/webroot/ROOT (wp-config.php not found)."
  exit 1
fi

WP="${WP:-wp}"  # override via WP=/path/to/wp if needed
ERR_LOG="backup_db.err.log"
: > "$ERR_LOG"

# -- 1) Charset via WP-CLI (as requested)
DB_CHARSET="$($WP eval 'global $wpdb; echo $wpdb->charset . PHP_EOL;' --allow-root --skip-plugins --skip-themes 2>>"$ERR_LOG" | tr -d '\r\n' || true)"
DB_CHARSET="${DB_CHARSET:-utf8mb4}"
info "Detected DB charset: ${DB_CHARSET}"

# -- 2) Parse DB creds from wp-config.php
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
  exit 1
fi

STAMP=$(date +%Y%m%d_%H%M%S)
OUT_FINAL="${DB_NAME}_${STAMP}.sql"
OUT_TMP="${OUT_FINAL}.tmp.$$"

# Clean up temp on error/interrupt
cleanup() {
  if [[ -f "$OUT_TMP" ]]; then
    warn "Leaving partial dump: ${OUT_FINAL}.partial.$(date +%s)"
    mv -f "$OUT_TMP" "${OUT_FINAL}.partial.$(date +%s)" 2>/dev/null || rm -f "$OUT_TMP" || true
  fi
}
trap cleanup INT TERM ERR

# -- 3) Host/port/socket handling
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

# -- 4) Optional capability flags
GTID_ARG=""; COLSTAT_ARG=""
mysqldump --help 2>/dev/null | grep -q -- "--set-gtid-purged"   && GTID_ARG="--set-gtid-purged=OFF"
mysqldump --help 2>/dev/null | grep -q -- "--column-statistics" && COLSTAT_ARG="--column-statistics=0"

# -- 5) EXACT base args you want (array preserved)
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

# -- 6) Space analysis: estimate DB size (bytes)
EST_DB_BYTES="$($WP db size --allow-root --skip-plugins --skip-themes --quiet --size_format=b 2>>"$ERR_LOG" | grep -Eo '^[0-9]+' || true)"
EST_DB_BYTES="${EST_DB_BYTES:-2147483648}"  # default 2 GiB if unknown
REQUIRED_BYTES=$(( (EST_DB_BYTES * 110) / 100 )) # +10% buffer
AVAIL_BYTES=$(df -B1 . | awk 'NR==2{print $4}')

echo
info "=== Disk Space Analysis ==="
echo "Estimated dump size:          $(numfmt --to=iec $EST_DB_BYTES)"
echo "Required (with 10% buffer):   $(numfmt --to=iec $REQUIRED_BYTES)"
echo "Available on target FS:       $(numfmt --to=iec $AVAIL_BYTES)"
echo

if (( AVAIL_BYTES < REQUIRED_BYTES )); then
  warn "Available space may be insufficient for a full dump."
  read -r -p "Proceed anyway? (y/N): " ans
  [[ ! $ans =~ ^[Yy]$ ]] && { warn "Aborted by user."; exit 0; }
else
  read -r -p "Proceed with DB backup? (Y/n): " ans
  ans=${ans:-Y}
  [[ ! $ans =~ ^[Yy]$ ]] && { warn "Aborted by user."; exit 0; }
fi

# -- 7) Dump with progress and safe write
log "Exporting database to $OUT_FINAL …"
if command -v pv >/dev/null 2>&1; then
  set +e
  MYSQL_PWD="$DB_PASSWORD" mysqldump "${BASE_ARGS[@]}" "$DB_NAME" 2>>"$ERR_LOG" \
    | pv -s "$EST_DB_BYTES" > "$OUT_TMP"
  DUMP_STATUS=${PIPESTATUS[0]}
  set -e
else
  warn "pv not found; showing basic progress (bytes written)…"
  set +e
  ( MYSQL_PWD="$DB_PASSWORD" mysqldump "${BASE_ARGS[@]}" "$DB_NAME" > "$OUT_TMP" 2>>"$ERR_LOG" ) &
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

# Fallback retry (without routines/events) if failed or empty
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
    MYSQL_PWD="$DB_PASSWORD" mysqldump "${SAFE_ARGS[@]}" "$DB_NAME" 2>>"$ERR_LOG" \
      | pv -s "$EST_DB_BYTES" > "$OUT_TMP"
    DUMP_STATUS=${PIPESTATUS[0]}
    set -e
  else
    set +e
    ( MYSQL_PWD="$DB_PASSWORD" mysqldump "${SAFE_ARGS[@]}" "$DB_NAME" > "$OUT_TMP" 2>>"$ERR_LOG" ) &
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
  err "Database export failed. See $ERR_LOG"
  exit 1
fi

# ---- 8) CONDITIONAL FIXES (collation / DEFINER) ----
NEED_COLLATION_FIX="no"
NEED_DEFINER_FIX="no"

# Quick existence checks (stop at first match)
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
    trap '[[ -f "$OUT_PROC" ]] && mv -f "$OUT_PROC" "${OUT_FINAL}.partial.$(date +%s).proc" 2>/dev/null || true' INT TERM ERR

    info "Applying fixes (streaming to processed file)…"
    if command -v pv >/dev/null 2>&1; then
      # Build sed program dynamically
      SED_PROG=()
      [[ "$NEED_DEFINER_FIX" == "yes" ]] && SED_PROG+=(-e 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' -e 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g')
      [[ "$NEED_COLLATION_FIX" == "yes" ]] && SED_PROG+=(-e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g')

      set +e
      pv -s "$(stat -c%s "$OUT_TMP")" "$OUT_TMP" \
        | sed -E "${SED_PROG[@]}" > "$OUT_PROC"
      PROC_STATUS=${PIPESTATUS[1]}
      set -e
    else
      warn "pv not found; showing basic progress (bytes written)…"
      SED_PROG_FILE="$(mktemp -p . sedprog.XXXXXX)"
      {
        [[ "$NEED_DEFINER_FIX" == "yes" ]] && echo 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g'
        [[ "$NEED_DEFINER_FIX" == "yes" ]] && echo 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g'
        [[ "$NEED_COLLATION_FIX" == "yes" ]] && echo 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
      } > "$SED_PROG_FILE"

      set +e
      ( sed -E -f "$SED_PROG_FILE" "$OUT_TMP" > "$OUT_PROC" ) &
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
      echo
      rm -f "$SED_PROG_FILE" || true
    fi

    if [[ ${PROC_STATUS:-0} -ne 0 || ! -s "$OUT_PROC" ]]; then
      err "Post-processing failed. Keeping original dump as partial. See $ERR_LOG"
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

SIZE=$(stat -c%s "$OUT_FINAL" 2>/dev/null || echo 0)
SHA=$(sha256sum "$OUT_FINAL" | awk '{print $1}')

echo
log "Database backup completed."
echo -e "${BLUE}Summary:${NC}"
echo "  Output: $(pwd)/$OUT_FINAL"
echo "  Size:   $(numfmt --to=iec $SIZE)"
echo "  Charset used: ${DB_CHARSET}"
echo "  SHA256: $SHA"
echo "  Log:    $(pwd)/$ERR_LOG"
