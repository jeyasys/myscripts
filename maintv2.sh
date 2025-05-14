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

if grep -q "WP_REDIS_CONFIG" wp-config.php; then
    echo "WP_REDIS_CONFIG is already defined – replacing it with the default configuration."
else
    echo "WP_REDIS_CONFIG is NOT defined – inserting default configuration."
fi
echo

perl -0777 -i -pe 's/define\s*\(\s*'\''WP_REDIS_CONFIG'\''.*?\]\s*\);[\s\n]*//s' wp-config.php

awk '
/define\(.*DB_PASSWORD.*/ && !printed {
    print $0
    print "define( '\''WP_REDIS_CONFIG'\'',"
    print "["
    print "'\''token'\'' => '\''79fb1487477c0a555d76e3249e1a1d2b975715293174f50afb456171301f'\'',"
    print "'\''host'\'' => '\''127.0.0.1'\'',"
    print "'\''port'\'' => 6379,"
    print "'\''database'\'' => 0,"
    print "'\''prefix'\'' => '\''dbdairy'\'',"
    print "'\''client'\'' => '\''relay'\'',"
    print "'\''timeout'\'' => 0.5,"
    print "'\''read_timeout'\'' => 0.5,"
    print "'\''retry_interval'\'' => 10,"
    print "'\''retries'\'' => 3,"
    print "'\''backoff'\'' => '\''smart'\'',"
    print "'\''compression'\'' => '\''zstd'\'',"
    print "'\''serializer'\'' => '\''igbinary'\'',"
    print "'\''async_flush'\'' => true,"
    print "'\''split_alloptions'\'' => true,"
    print "'\''prefetch'\'' => false,"
    print "'\''shared'\'' => true,"
    print "'\''debug'\'' => false,"
    print "'\''non_persistent_groups'\'' => ["
    print "    '\''comment'\'',"
    print "    '\''counts'\'',"
    print "    '\''plugins'\'',"
    print "    '\''themes'\'',"
    print "    '\''wc_session_id'\'',"
    print "    '\''learndash_reports'\'',"
    print "    '\''learndash_admin_profile'\''"
    print "]"
    print "]);"
    printed = 1
    next
}
{ print }
' wp-config.php > wp-config.tmp && mv wp-config.tmp wp-config.php

echo "WP_REDIS_CONFIG block added correctly."
echo

cd wp-content/plugins || exit

echo "Downloading Redis Cache Pro..."
wget -q -O redis-cache-pro.zip "https://objectcache.pro/plugin/redis-cache-pro.zip?token=79fb1487477c0a555d76e3249e1a1d2b975715293174f50afb456171301f"
echo

echo "Unzipping Redis Cache Pro..."
unzip -o redis-cache-pro.zip >/dev/null
rm redis-cache-pro.zip
echo "Redis Cache Pro extracted."
echo

cd ../../

echo "Activating Redis Cache Pro..."
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp plugin activate redis-cache-pro >/dev/null 2>&1
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp redis enable --force >/dev/null 2>&1
echo "Redis Cache Pro installation complete."
echo

echo "Installing LiteSpeed Cache..."
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp plugin install litespeed-cache --activate >/dev/null 2>&1
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp litespeed-option reset >/dev/null 2>&1
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp litespeed-option import_remote "https://raw.githubusercontent.com/alekzandrgw/public-download/refs/heads/main/litespeed-cache-defaults.data" >/dev/null 2>&1
echo "LiteSpeed Cache setup complete."
echo

echo "Installing Flush Opcache plugin..."
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp plugin install flush-opcache --quiet >/dev/null 2>&1
WP_CLI_PHP_ARGS="-d display_errors=Off -d error_reporting=E_ERROR" wp plugin activate flush-opcache --quiet >/dev/null 2>&1
echo "Flush Opcache plugin activated."
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
