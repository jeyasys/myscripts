#!/usr/bin/env bash

# Safer but not over-strict: only -u (undefined vars)
set -u

SCRIPT_PATH="$(realpath "$0")"
WP_ROOT="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
WP_CFG="$WP_ROOT/wp-config.php"

# Simple step marker
step() {
  local num="$1"
  local total="$2"
  local msg="$3"
  echo
  echo "[$num/$total] $msg"
  echo "-----------------------------------------------"
}

TOTAL_STEPS=3

#######################################
# Basic checks
#######################################
if [[ ! -f "$WP_CFG" ]]; then
  echo "Error: wp-config.php not found in $WP_ROOT"
  exit 1
fi

if ! command -v php >/dev/null 2>&1; then
  echo "Error: php command not found in PATH."
  exit 1
fi

#######################################
# Helper to read constants from wp-config.php
#######################################
get_const() {
  php -r "include '$WP_CFG'; echo defined('$1') ? constant('$1') : '';" 2>/dev/null
}

DB_NAME="$(get_const DB_NAME)"
DB_USER="$(get_const DB_USER)"
DB_PASS="$(get_const DB_PASSWORD)"
DB_HOST="$(get_const DB_HOST)"

[[ -n "${DB_HOST:-}" ]] || DB_HOST="127.0.0.1"

DB_AVAILABLE=1
if [[ -z "${DB_NAME:-}" || -z "${DB_USER:-}" ]]; then
  DB_AVAILABLE=0
fi

if ! command -v mysql >/dev/null 2>&1; then
  DB_AVAILABLE=0
fi

if [[ $DB_AVAILABLE -eq 1 ]]; then
  export MYSQL_PWD="${DB_PASS:-}"
fi

#######################################
# Header
#######################################
SG_TIME="$(TZ='Asia/Singapore' date +"%a %b %e %T %Z %Y")"

echo "==============================================="
echo " WordPress Pre-Migration Report"
echo "==============================================="
echo "Path       : $WP_ROOT"
echo "Generated  : $SG_TIME (Asia/Singapore)"
echo

#######################################
# Step 1: Filesystem summary
#######################################
step 1 "$TOTAL_STEPS" "Filesystem (WordPress root)"

# Human-readable total size
TOTAL_HUMAN=$(du -sh "$WP_ROOT" 2>/dev/null | cut -f1 || echo "N/A")

# Exact size in bytes for threshold check
TOTAL_BYTES=$(du -sb "$WP_ROOT" 2>/dev/null | cut -f1 || echo 0)

echo "Total size : $TOTAL_HUMAN"

THRESHOLD_BYTES=$((10 * 1024 * 1024 * 1024))  # 10 GB

if [[ "$TOTAL_BYTES" -gt "$THRESHOLD_BYTES" ]]; then
  echo
  echo "Total size is above 10 GB."
  echo "Top 10 largest files under $WP_ROOT:"
  echo

  (
    cd "$WP_ROOT" || exit 0

    if command -v numfmt >/dev/null 2>&1; then
      # Use bytes + numfmt (more robust and fast)
      find . -type f -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn 2>/dev/null \
        | head -n 10 \
        | while IFS=$'\t' read -r size path; do
            human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")
            printf "%-10s %s\n" "$human" "$path"
          done
    else
      # Fallback: du -sh (can be slower, but no extra deps)
      find . -type f -exec du -sh {} + 2>/dev/null \
        | sort -rh 2>/dev/null \
        | head -n 10
    fi
  ) || echo "Warning: Failed to list largest files (permissions or load)."
fi

#######################################
# Step 2: Database summary
#######################################
step 2 "$TOTAL_STEPS" "Database summary"

if [[ $DB_AVAILABLE -eq 0 ]]; then
  echo "Database info not available."
  echo "Either mysql client is missing, or DB_NAME/DB_USER could not be read from wp-config.php."
else
  echo "Database   : $DB_NAME"
  echo "DB Host    : $DB_HOST"
  echo

  echo "Total database size (MB):"
  if ! mysql -h "$DB_HOST" -u "$DB_USER" -e "
    SELECT table_schema AS 'Database',
           ROUND(SUM(data_length + index_length)/1024/1024, 2) AS 'Size_MB'
    FROM information_schema.tables
    WHERE table_schema = '$DB_NAME'
    GROUP BY table_schema;
  "; then
    echo "Error: Unable to query database size."
  fi

  echo
  echo "Top 10 tables by row count:"
  if ! mysql -h "$DB_HOST" -u "$DB_USER" -e "
    SELECT table_name AS 'Table',
           table_rows AS 'Rows',
           ROUND((data_length + index_length)/1024/1024, 2) AS 'Size_MB'
    FROM information_schema.tables
    WHERE table_schema = '$DB_NAME'
    ORDER BY table_rows DESC
    LIMIT 10;
  "; then
    echo "Error: Unable to query table statistics."
  fi
fi

#######################################
# Step 3: Finish & self-destruct
#######################################
step 3 "$TOTAL_STEPS" "Finalizing"

echo "Report complete."
echo "Script will now self-destruct."
echo

rm -f -- "$SCRIPT_PATH" || echo "Warning: Failed to delete script ($SCRIPT_PATH)."
