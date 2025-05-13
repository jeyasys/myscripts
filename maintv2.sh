#!/bin/bash

comment="/* That's all, stop editing! Happy publishing. */"

if grep -Fxq "$comment" wp-config.php
then
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

if grep -q "^define( 'WP_REDIS_CONFIG'," wp-config.php; then
    echo "WP_REDIS_CONFIG is already defined."
else
    echo "WP_REDIS_CONFIG is NOT defined."
fi

auto_update_line="define('AUTOMATIC_UPDATER_DISABLED', true);"
if grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*true\s*);" wp-config.php; then
    echo "Auto-update is already disabled."
elif grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);/define('AUTOMATIC_UPDATER_DISABLED', true);/g" wp-config.php
    echo "Auto-update was enabled, now disabled."
else
    insert_after "Happy publishing" "$auto_update_line" wp-config.php
    echo "Auto-update was not defined, now disabled."
fi

disable_wp_cron_line="define('DISABLE_WP_CRON', true);"
if grep -q "define(\s*'DISABLE_WP_CRON',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'DISABLE_WP_CRON',\s*false\s*);/define('DISABLE_WP_CRON', true);/g" wp-config.php
    echo "DISABLE_WP_CRON set to true."
elif ! grep -q "define(\s*'DISABLE_WP_CRON',\s*true\s*);" wp-config.php; then
    insert_after "Happy publishing" "$disable_wp_cron_line" wp-config.php
    echo "DISABLE_WP_CRON was not set, now set to true."
else
    echo "DISABLE_WP_CRON already set to true."
fi

cd wp-content/plugins
wget -O redis-cache-pro.zip "https://objectcache.pro/plugin/redis-cache-pro.zip?token=79fb1487477c0a555d76e3249e1a1d2b975715293174f50afb456171301f" && unzip redis-cache-pro.zip
rm redis-cache-pro.zip
cd -

wp plugin activate redis-cache-pro
wp redis enable --force

wp plugin install litespeed-cache --activate
wp litespeed-option reset
wp litespeed-option import_remote "https://raw.githubusercontent.com/alekzandrgw/public-download/refs/heads/main/litespeed-cache-defaults.data"

wp plugin install flush-opcache --quiet
wp plugin activate flush-opcache --quiet
wp litespeed-purge all --quiet
wp cache flush --quiet
wp redis flush --quiet
wp rewrite flush --hard --quiet

if [ -d wp-content/uploads/bb-platform-previews/ ]; then
    rm -rf wp-content/uploads/bb-platform-previews/*
    echo "Cleaned bb-platform-previews directory."
else
    echo "bb-platform-previews directory does not exist."
fi

redis-cli -s /var/run/redis/redis.sock FLUSHALL
echo "All Redis caches flushed."

redis-cli -s /var/run/redis/redis.sock FLUSHDB
echo "Current Redis database flushed."

if wp plugin is-installed woocommerce-subscriptions; then
    echo -e "\033[1;31mWoo Subscription detected! Make sure to update the URL and disable WP cron.\033[0m"
fi

echo "Script will be destroyed now."
rm -- "$0"
