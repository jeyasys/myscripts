#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_PATH="$(realpath "$0")"
WP_ROOT="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
WP_CFG="$WP_ROOT/wp-config.php"

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

if ! command -v mysql >/dev/null 2>&1; then
  echo "Error: mysql client not found in PATH."
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

if [[ -z "${DB_NAME:-}" || -z "${DB_USER:-}" || -z "${DB_PASS:-}" ]]; then
  echo "Error: Could not read DB_NAME, DB_USER or DB_PASSWORD from wp-config.php"
  exit 1
fi

[[ -n "${DB_HOST:-}" ]] || DB_HOST="127.0.0.1"

export MYSQL_PWD="$DB_PASS"

#######################################
# Header
#######################################
echo "==============================================="
echo " WordPress Pre-Migration Report"
echo "==============================================="
echo "Path       : $WP_ROOT"
echo "Generated  : $(date)"
echo

#######################################
# Filesystem summary
#######################################
echo "-----------------------------------------------"
echo " Filesystem (WordPress root)"
echo "-----------------------------------------------"

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

  if command -v numfmt >/dev/null 2>&1; then
    (
      cd "$WP_ROOT"
      # Use size in bytes, then convert to human-readable with numfmt
      find . -type f -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn \
        | head -n 10 \
        | while IFS=$'\t' read -r size path; do
            human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")
            printf "%-10s %s\n" "$human" "$path"
          done
    )
  else
    (
      cd "$WP_ROOT"
      # Fallback to du -sh (slower, but works without numfmt)
      find . -type f -exec du -sh {} + 2>/dev/null \
        | sort -rh \
        | head -n 10
    )
  fi
fi

#######################################
# Database summary
#######################################
echo
echo "-----------------------------------------------"
echo " Database ($DB_NAME)"
echo "-----------------------------------------------"

# Total DB size
echo "Total database size (MB):"
mysql -h "$DB_HOST" -u "$DB_USER" -e "
SELECT table_schema AS 'Database',
       ROUND(SUM(data_length + index_length)/1024/1024, 2) AS 'Size_MB'
FROM information_schema.tables
WHERE table_schema = '$DB_NAME'
GROUP BY table_schema;
" || echo "Error: Unable to query database size."

echo
echo "Top 10 tables by row count:"
mysql -h "$DB_HOST" -u "$DB_USER" -e "
SELECT table_name AS 'Table',
       table_rows AS 'Rows',
       ROUND((data_length + index_length)/1024/1024, 2) AS 'Size_MB'
FROM information_schema.tables
WHERE table_schema = '$DB_NAME'
ORDER BY table_rows DESC
LIMIT 10;
" || echo "Error: Unable to query table statistics."

echo
echo "-----------------------------------------------"
echo " Report complete. Script will now self-destruct."
echo "-----------------------------------------------"

# Self-delete
rm -f -- "$SCRIPT_PATH"
