#!/bin/bash

insert_after_line() {
    local pattern="$1"
    local insert_line="$2"
    local file="$3"
    sed -i "/$pattern/a $insert_line" "$file"
}

table_prefix_pattern="^\s*\$table_prefix\s*="
auto_update_line="define('AUTOMATIC_UPDATER_DISABLED', true);"
disable_wp_cron_line="define('DISABLE_WP_CRON', true);"

# 1. Auto-update line
if grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*true\s*);" wp-config.php; then
    echo "Auto-update is already disabled."
    echo
elif grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);/$auto_update_line/g" wp-config.php
    echo "Auto-update was enabled, now disabled."
    echo
else
    insert_after_line "$table_prefix_pattern" "$auto_update_line" wp-config.php
    echo "Auto-update setting inserted after \$table_prefix."
    echo
fi

# 2. Disable wp-cron line
if grep -q "define(\s*'DISABLE_WP_CRON',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'DISABLE_WP_CRON',\s*false\s*);/$disable_wp_cron_line/g" wp-config.php
    echo "DISABLE_WP_CRON set to true."
    echo
elif ! grep -q "define(\s*'DISABLE_WP_CRON',\s*true\s*);" wp-config.php; then
    insert_after_line "$table_prefix_pattern" "$disable_wp_cron_line" wp-config.php
    echo "DISABLE_WP_CRON setting inserted after \$table_prefix."
    echo
else
    echo "DISABLE_WP_CRON already set to true."
    echo
fi

# Remove any existing WP_REDIS_* defines
perl -0777 -i -pe "
s/define\s*\(\s*'WP_REDIS_SCHEME'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_PORT'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_PREFIX'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_DATABASE'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_CLIENT'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_TIMEOUT'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_READ_TIMEOUT'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_RETRY_INTERVAL'[^;]*;\s*//g;
s/define\s*\(\s*'WP_REDIS_HOST'[^;]*;\s*//g;
" wp-config.php

perl -0777 -i -pe "s/define\s*\(\s*'WP_REDIS_CONFIG'.*?\]\s*\);[\s\n]*//s" wp-config.php

dir_name=$(pwd | cut -d'/' -f3)
prefix_name=$(echo "$dir_name" | sed 's/^web/db/')

redis_define_block=$(cat <<EOF
define( 'WP_REDIS_SCHEME', 'tcp' );
define( 'WP_REDIS_PORT', '6379' );
define( 'WP_REDIS_PREFIX', '${prefix_name}' );
define( 'WP_REDIS_DATABASE', '0' );
define( 'WP_REDIS_CLIENT', 'phpredis' );
define( 'WP_REDIS_TIMEOUT', '0.5' );
define( 'WP_REDIS_READ_TIMEOUT', '0.5' );
define( 'WP_REDIS_RETRY_INTERVAL', '10' );
define( 'WP_REDIS_HOST', '127.0.0.1' );
EOF
)

awk -v block="$redis_define_block" '
/\$table_prefix\s*=/ && !printed {
    print $0
    print block
    printed = 1
    next
}
{ print }
' wp-config.php > wp-config.tmp && mv wp-config.tmp wp-config.php

echo "WP_REDIS_* block added correctly."
echo

# Install and activate Redis Cache plugin
echo "Installing Redis Cache plugin..."
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp plugin install redis-cache --activate --quiet >/dev/null 2>&1
echo "Redis Cache plugin installed and activated."
echo

echo "Flushing WordPress object cache..."
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp cache flush --quiet >/dev/null 2>&1
echo

echo "Flushing Redis cache..."
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp redis flush --quiet >/dev/null 2>&1
echo

echo "Flushing rewrite rules..."
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp rewrite flush --hard --quiet >/dev/null 2>&1
echo

if [ -d wp-content/uploads/bb-platform-previews/ ]; then
    rm -rf wp-content/uploads/bb-platform-previews/*
    echo "Preview directory cleaned."
    echo
else
    echo "Preview directory does not exist."
    echo
fi

if WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp plugin is-installed woocommerce-subscriptions >/dev/null 2>&1; then
    echo -e "\033[1;31mWoo Subscription detected! Consider running:\nwp option update wc_subscriptions_siteurl https://example.com-staging\033[0m"
    echo
fi

echo "Script will be destroyed now."
echo
rm -- "$0"
