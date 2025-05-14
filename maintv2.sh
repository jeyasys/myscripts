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

# Insert or update AUTO UPDATER setting
if grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*true\s*);" wp-config.php; then
    echo "Auto-update is already disabled."
elif grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);/$auto_update_line/g" wp-config.php
    echo "Auto-update was enabled, now disabled."
else
    insert_after_line "$table_prefix_pattern" "$auto_update_line" wp-config.php
    echo "Auto-update setting inserted after \$table_prefix."
fi

# Insert or update DISABLE_WP_CRON setting
if grep -q "define(\s*'DISABLE_WP_CRON',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'DISABLE_WP_CRON',\s*false\s*);/$disable_wp_cron_line/g" wp-config.php
    echo "DISABLE_WP_CRON set to true."
elif ! grep -q "define(\s*'DISABLE_WP_CRON',\s*true\s*);" wp-config.php; then
    insert_after_line "$table_prefix_pattern" "$disable_wp_cron_line" wp-config.php
    echo "DISABLE_WP_CRON setting inserted after \$table_prefix."
else
    echo "DISABLE_WP_CRON already set to true."
fi

# Check and insert WP_REDIS_CONFIG block
if grep -q "^define( 'WP_REDIS_CONFIG'," wp-config.php; then
    echo "WP_REDIS_CONFIG is already defined."
else
    echo "WP_REDIS_CONFIG is NOT defined. Adding it..."

    redis_config=$(cat <<'EOF'
define( 'WP_REDIS_CONFIG',
[
'token' => '79fb1487477c0a555d76e3249e1a1d2b975715293174f50afb456171301f',
'host' => '127.0.0.1',
'port' => 6379,
'database' => 0,
'prefix' => 'dbdairy',
'client' => 'relay',
'timeout' => 0.5,
'read_timeout' => 0.5,
'retry_interval' => 10,
'retries' => 3,
'backoff' => 'smart',
'compression' => 'zstd',
'serializer' => 'igbinary',
'async_flush' => true,
'split_alloptions' => true,
'prefetch' => false,
'shared' => true,
'debug' => false,
'non_persistent_groups' => [
    'comment',
    'counts',
    'plugins',
    'themes',
    'wc_session_id',
    'learndash_reports',
    'learndash_admin_profile',
],
]
);
EOF
)

    sed -i "/define(\s*'DB_PASSWORD'.*/a $redis_config" wp-config.php
    echo "WP_REDIS_CONFIG block inserted after DB_PASSWORD."
fi

# Redis Cache Pro setup
cd wp-content/plugins || exit

echo "Downloading Redis Cache Pro..."
wget -O redis-cache-pro.zip "https://objectcache.pro/plugin/redis-cache-pro.zip?token=79fb1487477c0a555d76e3249e1a1d2b975715293174f50afb456171301f"
echo "Unzipping Redis Cache Pro..."
unzip redis-cache-pro.zip >/dev/null
rm redis-cache-pro.zip
echo "Redis Cache Pro extracted."

cd ../../

echo "Activating Redis Cache Pro..."
wp plugin activate redis-cache-pro
wp redis enable --force
echo "Redis Cache Pro installation complete."

# Install and configure LiteSpeed Cache
echo "Installing LiteSpeed Cache..."
wp plugin install litespeed-cache --activate
wp litespeed-option reset
wp litespeed-option import_remote "https://raw.githubusercontent.com/alekzandrgw/public-download/refs/heads/main/litespeed-cache-defaults.data"
echo "LiteSpeed Cache setup complete."

# Install and activate Flush Opcache
echo "Installing Flush Opcache plugin..."
wp plugin install flush-opcache --quiet
wp plugin activate flush-opcache --quiet
echo "Flush Opcache plugin activated."

# Cache flushing
echo "Flushing WordPress object cache..."
wp cache flush --quiet
echo "Flushing Redis cache..."
wp redis flush --quiet
echo "Flushing rewrite rules..."
wp rewrite flush --hard --quiet

# Clean previews directory
if [ -d wp-content/uploads/bb-platform-previews/ ]; then
    rm -rf wp-content/uploads/bb-platform-previews/*
    echo "Preview directory cleaned."
else
    echo "Preview directory does not exist."
fi

# WooCommerce Subscriptions warning
if wp plugin is-installed woocommerce-subscriptions; then
    echo -e "\033[1;31mWoo Subscription detected! Consider running:\nwp option update wc_subscriptions_siteurl https://example.com-staging\033[0m"
fi

# Final cleanup
echo "Script will be destroyed now."
rm -- "$0"
