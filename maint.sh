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

# Install and activate the LiteSpeed Cache plugin
wp plugin install litespeed-cache --quiet
wp plugin activate litespeed-cache --quiet

# Install and activate the Flush Opcache plugin
wp plugin install flush-opcache --quiet
wp plugin activate flush-opcache --quiet

# Purge all caches in LiteSpeed
wp litespeed-purge all --quiet

# Flush the WordPress object cache
wp cache flush --quiet


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
