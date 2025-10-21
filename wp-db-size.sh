#!/usr/bin/env bash

set -Eeuo pipefail
SCRIPT_PATH="$(realpath "$0")"   # this script's own file

WP_CFG="./wp-config.php"
[[ -f "$WP_CFG" ]] || { echo "wp-config.php not found"; exit 1; }

get_const() {
  php -r "include '$WP_CFG'; echo defined('$1') ? constant('$1') : '';" 2>/dev/null
}

DB_NAME="$(get_const DB_NAME)"
DB_USER="$(get_const DB_USER)"
DB_PASS="$(get_const DB_PASSWORD)"

export MYSQL_PWD="$DB_PASS"

mysql -h 127.0.0.1 -u "$DB_USER" -e "
SELECT table_schema AS 'Database',
       ROUND(SUM(data_length + index_length)/1024/1024, 2) AS 'Size_MB'
FROM information_schema.tables
WHERE table_schema='$DB_NAME'
GROUP BY table_schema;
"

rm -f "$SCRIPT_PATH"
