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
# (trim whitespace/newlines in PHP itself)
#######################################
get_const() {
  php -r "
    include '$WP_CFG';
    if (defined('$1')) {
      \$v = constant('$1');
      if (is_string(\$v)) {
        echo trim(\$v);
      } else {
        echo \$v;
      }
    }
  " 2>/dev/null
}

# Constants (used mainly for MySQL fallback; DB_NAME also for display)
DB_NAME="$(get_const DB_NAME)"
DB_USER="$(get_const DB_USER)"
DB_PASS="$(get_const DB_PASSWORD)"
DB_HOST="$(get_const DB_HOST)"
[[ -n "${DB_HOST:-}" ]] || DB_HOST="127.0.0.1"

# Extra sanitize in shell (strip any stray newlines)
DB_NAME="$(echo "${DB_NAME:-}" | tr -d '\r\n')"

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

echo "Total size : $TOTAL_HUMAN"
echo
echo
echo "Disk Space Summary:"

# Detect main filesystem for WP root
DF_LINE=$(df -k "$WP_ROOT" | tail -1)

DF_SIZE=$(echo "$DF_LINE" | awk '{print $2}')
DF_USED=$(echo "$DF_LINE" | awk '{print $3}')
DF_AVAIL=$(echo "$DF_LINE" | awk '{print $4}')
DF_USEP=$(echo "$DF_LINE" | awk '{print $5}')

# Convert KB → human readable (same as df -h)
HR_SIZE=$(numfmt --to=iec --suffix=B "$((DF_SIZE * 1024))")
HR_USED=$(numfmt --to=iec --suffix=B "$((DF_USED * 1024))")
HR_AVAIL=$(numfmt --to=iec --suffix=B "$((DF_AVAIL * 1024))")

printf "+--------------+--------------+--------------+--------+\n"
printf "| Total        | Used         | Available    | Use%%  |\n"
printf "+--------------+--------------+--------------+--------+\n"
printf "| %-12s | %-12s | %-12s | %-6s |\n" "$HR_SIZE" "$HR_USED" "$HR_AVAIL" "$DF_USEP"
printf "+--------------+--------------+--------------+--------+\n\n"
echo "Top 20 largest files under $WP_ROOT:"
echo

(
  cd "$WP_ROOT" || exit 0

  if command -v numfmt >/dev/null 2>&1; then
    # Fast & reliable: use bytes, then convert to human
    find . -type f -printf '%s\t%p\n' 2>/dev/null \
      | sort -rn 2>/dev/null \
      | head -n 20 \
      | while IFS=$'\t' read -r size path; do
          human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")
          printf "%-10s %s\n" "$human" "$path"
        done
  else
    # Fallback: du -sh for each file (slower)
    find . -type f -exec du -sh {} + 2>/dev/null \
      | sort -rh 2>/dev/null \
      | head -n 20
  fi
) || echo "Warning: Failed to list largest files (permissions or load)."

#######################################
# Step 2: Database summary (WP-CLI first, then MySQL fallback)
#######################################
step 2 "$TOTAL_STEPS" "Database summary"

if command -v wp >/dev/null 2>&1; then
  ###################################
  # Primary path: WP-CLI
  ###################################
  echo "Using WP-CLI for database detection (skip plugins/themes)."
  echo

  (
    cd "$WP_ROOT" || exit 0

    # DB name row
    if [[ -n "${DB_NAME:-}" ]]; then
      echo "Database   : $DB_NAME"
      echo
    fi

    echo "Total database size (MB):"
    # Get just the number from wp db size
    DB_TOTAL_MB="$(wp --skip-plugins --skip-themes db size --size_format=mb --quiet 2>/dev/null || echo "")"

    if [[ -n "$DB_TOTAL_MB" ]]; then
      printf "+----------------+---------+\n"
      printf "| Database       | Size_MB |\n"
      printf "+----------------+---------+\n"
      printf "| %-14s | %7s |\n" "${DB_NAME:-DATABASE}" "$DB_TOTAL_MB"
      printf "+----------------+---------+\n"
    else
      echo "Warning: wp db size failed."
    fi

    echo
    echo "Top 20 tables by row count:"
    wp --skip-plugins --skip-themes db query "
      SELECT table_name AS 'Table',
             table_rows AS 'Rows',
             ROUND((data_length + index_length)/1024/1024, 2) AS 'Size_MB'
      FROM information_schema.tables
      WHERE table_schema = DATABASE()
      ORDER BY table_rows DESC
      LIMIT 20;
    " || echo "Warning: wp db query failed (see error above)."
  )

else
  ###################################
  # Fallback path: mysql + wp-config
  ###################################
  echo "WP-CLI not found. Falling back to mysql + wp-config.php."
  echo

  DB_AVAILABLE=1
  DB_REASON=""

  if [[ -z "${DB_NAME:-}" || -z "${DB_USER:-}" ]]; then
    DB_AVAILABLE=0
    DB_REASON="DB_NAME or DB_USER could not be read from wp-config.php."
  fi

  if ! command -v mysql >/dev/null 2>&1; then
    DB_AVAILABLE=0
    if [[ -n "$DB_REASON" ]]; then
      DB_REASON="$DB_REASON mysql client not found in PATH."
    else
      DB_REASON="mysql client not found in PATH."
    fi
  fi

  if [[ $DB_AVAILABLE -eq 0 ]]; then
    echo "Database info not available."
    [[ -n "$DB_REASON" ]] && echo "$DB_REASON"
  else
    export MYSQL_PWD="${DB_PASS:-}"

    echo "Database   : ${DB_NAME:-UNKNOWN}"
    echo "DB Host    : ${DB_HOST:-UNKNOWN}"
    echo

    echo "Total database size (MB):"
    mysql -h "$DB_HOST" -u "$DB_USER" -e "
      SELECT table_schema AS 'Database',
             ROUND(SUM(data_length + index_length)/1024/1024, 2) AS 'Size_MB'
      FROM information_schema.tables
      WHERE table_schema = '$DB_NAME'
      GROUP BY table_schema;
    " || echo "Error: Unable to query database size (see MySQL error above)."

    echo
    echo "Top 20 tables by row count:"
    mysql -h "$DB_HOST" -u "$DB_USER" -e "
      SELECT table_name AS 'Table',
             table_rows AS 'Rows',
             ROUND((data_length + index_length)/1024/1024, 2) AS 'Size_MB'
      FROM information_schema.tables
      WHERE table_schema = '$DB_NAME'
      ORDER BY table_rows DESC
      LIMIT 20;
    " || echo "Error: Unable to query table statistics (see MySQL error above)."
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
