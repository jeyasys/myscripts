#!/bin/bash

# Define the comment to be added
comment="/* That's all, stop editing! Happy publishing. */"

# Check if the line already exists in wp-config.php
if grep -Fxq "$comment" wp-config.php
then
    echo "Happy publishing line is already there."
else
    # Insert the comment before 'require_once ABSPATH . 'wp-settings.php';'
    sed -i "/^\s*require_once\s*ABSPATH\s*\.\s*'wp-settings.php';/i $comment" wp-config.php
   echo "Happy publishing line was not there, but it's added now."
fi





# Define the lines to be added
auto_update_line="define('AUTOMATIC_UPDATER_DISABLED', true);"
disable_wp_cron_line="define('DISABLE_WP_CRON', true);"

# Function to insert a line before the matching pattern
insert_before() {
    local pattern="$1"
    local insert_line="$2"
    local file="$3"
    sed -i "/^\s*$pattern/i $insert_line" "$file"
}

# Check if AUTOMATIC_UPDATER_DISABLED is already set to true
if grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*true\s*);" wp-config.php; then
    echo "Auto-update is already disabled."
elif grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);" wp-config.php; then
    # Replace false with true
    sed -i "s/define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);/define('AUTOMATIC_UPDATER_DISABLED', true);/g" wp-config.php
    echo "Auto-update was enabled, but now it's disabled."
else
    # Add the line if missing
    insert_before "require_once ABSPATH . 'wp-settings.php';" "$auto_update_line" wp-config.php
    echo "Auto-update was not defined, it's disabled now."
fi

# Check if DISABLE_WP_CRON is already set to true
if grep -q "define(\s*'DISABLE_WP_CRON',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'DISABLE_WP_CRON',\s*false\s*);/define('DISABLE_WP_CRON', true);/g" wp-config.php
    echo "DISABLE_WP_CRON was set to false, but it's set to true now."
elif ! grep -q "define(\s*'DISABLE_WP_CRON',\s*true\s*);" wp-config.php; then
    # Add the line if missing
    insert_before "require_once ABSPATH . 'wp-settings.php';" "$disable_wp_cron_line" wp-config.php
    echo "DISABLE_WP_CRON was not set, but it's set to true now."
else
    echo "DISABLE_WP_CRON is already set to true."
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

# If you have Redis cache installed and want to flush it as well
wp redis flush --quiet

# Flush rewrite rules (resave permalinks)
wp rewrite flush --hard --quiet


#truncate -s 0 1
#chmod 400 1

# Check if the commands were successful and echo a corresponding message
#if [ $? -eq 0 ]; then
#    echo "Successfully truncated the error log file and changed the chmod permission to 400."
#else
#    echo "Error: Unable to perform the required operations on the error log file."
#fi

# Empty the wp-content/uploads/bb-platform-previews/ directory
if [ -d wp-content/uploads/bb-platform-previews/ ]; then
    rm -rf wp-content/uploads/bb-platform-previews/*
    echo "The directory wp-content/uploads/bb-platform-previews/ has been emptied."
else
    echo "The directory wp-content/uploads/bb-platform-previews/ does not exist."
fi



# Flush Redis cache
redis-cli -s /var/run/redis/redis.sock FLUSHALL
echo "All Redis caches flushed."

redis-cli -s /var/run/redis/redis.sock FLUSHDB
echo "Current Redis database flushed."

echo "Redis cache flushed"

#Set WordPress Site to Private Mode (Tick "Discourage search engines from indexing this site")
#wp option set blog_public 0

site_url=$(wp option get siteurl)
current_blog_public=$(wp option get blog_public)

echo "Current site URL: $site_url"
echo "Current status of search engine visibility (blog_public): $current_blog_public"

# Scenario 1: Site URL ends with rapydapps.cloud
if [[ $site_url == *".rapydapps.cloud" ]]; then
    if [ "$current_blog_public" -eq 0 ]; then
        echo "Search engine visibility has already been set to discourage indexing."
    else
        wp option set blog_public 0
        echo "Search engine visibility has been marked to discourage indexing (Set blog_public to 0)."
    fi
# Scenario 2: Site URL does not end with rapydapps.cloud
else
    if [ "$current_blog_public" -eq 0 ]; then
        wp option set blog_public 1
        echo "Search engine visibility has been restored to public indexing (Set blog_public to 1)."
    else
        echo "Search engine visibility has already been restored to public indexing."
    fi
fi



if wp plugin is-installed woocommerce-subscriptions; then
    echo -e "\033[1;31mWoo Subscription detected! Make sure to update the URL (wp option update wc_subscriptions_siteurl https://example.com-staging) and disable the WP cron.\033[0m"
fi

# Notify before deleting the script
echo "Script will be destroyed now."

# Delete the script itself
rm -- "$0"
