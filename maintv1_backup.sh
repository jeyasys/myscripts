#!/bin/bash

comment="/* That's all, stop editing! Happy publishing. */"

if grep -Fxq "$comment" wp-config.php; then
    echo "Happy publishing line is already there."
else
    sed -i "/^\s*require_once\s*ABSPATH\s*\.\s*'wp-settings.php';/i $comment" wp-config.php
    echo "Happy publishing line was not there, but it's added now."
fi

insert_after() {
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
elif grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);/$auto_update_line/g" wp-config.php
    echo "Auto-update was enabled, but now it's disabled."
else
    insert_after "$table_prefix_pattern" "$auto_update_line" wp-config.php
    echo "Auto-update was not defined, it's disabled now."
fi

if grep -q "define(\s*'DISABLE_WP_CRON',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'DISABLE_WP_CRON',\s*false\s*);/$disable_wp_cron_line/g" wp-config.php
    echo "DISABLE_WP_CRON was set to false, but it's set to true now."
elif ! grep -q "define(\s*'DISABLE_WP_CRON',\s*true\s*);" wp-config.php; then
    insert_after "$table_prefix_pattern" "$disable_wp_cron_line" wp-config.php
    echo "DISABLE_WP_CRON was not set, but it's set to true now."
else
    echo "DISABLE_WP_CRON is already set to true."
fi

expected_token="79fb1487477c0a555d76e3249e1a1d2b975715293174f50afb456171301f"

if grep -q "WP_REDIS_CONFIG" wp-config.php; then
    existing_token=$(awk '/WP_REDIS_CONFIG/,/\)/' wp-config.php | grep -o "'token' => '[^']*'" | cut -d"'" -f4)
    
    if [[ "$existing_token" == "$expected_token" ]]; then
        echo "WP_REDIS_CONFIG is already set with correct token. No replacement needed."
    else
        echo "WP_REDIS_CONFIG is defined with a different token ($existing_token). Replacing it."
        perl -0777 -i -pe "s/define\s*\(\s*'WP_REDIS_CONFIG'.*?\]\s*\);[\s\n]*//s" wp-config.php
    fi
else
    echo "WP_REDIS_CONFIG is not defined. Adding it."
fi


if ! grep -q "79fb1487477c0a555d76e3249e1a1d2b975715293174f50afb456171301f" wp-config.php; then
redis_block=$(cat <<'EOF'
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
'compression' => 'zstd', // Zstandard (level 3)
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

awk -v block="$redis_block" '
/\$table_prefix\s*=/ && !printed {
    print $0
    print block
    printed = 1
    next
}
{ print }
' wp-config.php > wp-config.tmp && mv wp-config.tmp wp-config.php

echo "WP_REDIS_CONFIG block inserted."
fi

wp plugin install litespeed-cache --quiet
wp plugin activate litespeed-cache --quiet
wp plugin install flush-opcache --quiet
wp plugin activate flush-opcache --quiet

wp redis enable --force --quiet

wp litespeed-purge all --quiet
wp cache flush --quiet
wp redis flush --quiet

wp rewrite flush --hard --quiet

if [ -d wp-content/uploads/bb-platform-previews/ ]; then
    rm -rf wp-content/uploads/bb-platform-previews/*
    echo "The directory wp-content/uploads/bb-platform-previews/ has been emptied."
else
    echo "The directory wp-content/uploads/bb-platform-previews/ does not exist."
fi

redis-cli -s /var/run/redis/redis.sock FLUSHALL
echo "All Redis caches flushed."

redis-cli -s /var/run/redis/redis.sock FLUSHDB
echo "Current Redis database flushed."

echo "Redis cache flushed"

if wp plugin is-installed woocommerce-subscriptions; then
    echo -e "\033[1;31mWoo Subscription detected! Make sure to update the URL (wp option update wc_subscriptions_siteurl https://example.com-staging) and disable the WP cron.\033[0m"
fi

echo "Script will be destroyed now."
rm -- "$0"
