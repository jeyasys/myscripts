#!/usr/bin/env bash
# Get total WordPress DB size (always using -h 127.0.0.1)

set -Eeuo pipefail

# Path to wp-config.php (current dir or optional first argument)
WP_CFG="${1:-./wp-config.php}"

if [[ ! -f "$WP_CFG" ]]; then
  echo "Error: wp-config.php not found at $WP_CFG"
  exit 1
fi

# Function to extract constants from wp-config.php
get_const() {
  php -r "include '$WP_CFG'; echo defined('$1') ? constant('$1') : '';" 2>/dev/null
}

DB_NAME="$(get_const DB_NAME)"
DB_USER="$(get_const DB_USER)"
DB_PASS="$(get_const DB_PASSWORD)"

if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
  echo "Error: Missing DB_NAME or DB_USER in wp-config.php"
  exit 1
fi

# Pass password using env var (no prompt)
export MYSQL_PWD="$DB_PASS"

# Run query
mysql -h 127.0.0.1 -u "$DB_USER" -e "
SELECT table_schema AS 'Database',
       ROUND(SUM(data_length + index_length)/1024/1024, 2) AS 'Size_MB'
FROM information_schema.tables
WHERE table_schema='$DB_NAME'
GROUP BY table_schema;
"
