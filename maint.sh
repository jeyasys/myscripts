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

# Check if the disable auto update block exists
if grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*true\s*);" wp-config.php; then
    echo "Auto-update is already disabled."
elif grep -q "define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);" wp-config.php; then
    # Replace false with true
    sed -i "s/define(\s*'AUTOMATIC_UPDATER_DISABLED',\s*false\s*);/define('AUTOMATIC_UPDATER_DISABLED', true);/g" wp-config.php
    echo "Auto-update was enabled, but now it's disabled."
else
    # Add the code block if missing
    echo "/* Disable all site auto updates  */" >> wp-config.php
    echo "define( 'AUTOMATIC_UPDATER_DISABLED', true );" >> wp-config.php
    echo "Auto update was not defined, it's disabled now."
fi



# Check if DISABLE_WP_CRON is set to false and replace it with true
if grep -q "define(\s*'DISABLE_WP_CRON',\s*false\s*);" wp-config.php; then
    sed -i "s/define(\s*'DISABLE_WP_CRON',\s*false\s*);/define('DISABLE_WP_CRON', true);/g" wp-config.php
    echo "DISABLE_WP_CRON was set to false, but it's set to true now."
elif ! grep -q "define(\s*'DISABLE_WP_CRON',\s*true\s*);" wp-config.php; then
    # If DISABLE_WP_CRON is not defined at all, then add it as true
    echo "define('DISABLE_WP_CRON', true);" >> wp-config.php
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

# Check if the site URL ends with rapydapps.cloud
if [[ $site_url == *".rapydapps.cloud" ]]; then
    # If it does, set blog_public to 0
    wp option set blog_public 0
    echo "Set blog_public to 0 as the site URL ends with rapydapps.cloud."
else
    # If it doesn't, set blog_public to 1
    wp option set blog_public 1
    echo "Set blog_public to 1 as the site URL does not end with rapydapps.cloud."
fi


if wp plugin is-installed woocommerce; then
    echo -e "\033[1;31mWooCommerce detected. Make sure to check for the subscription module.\033[0m"
fi

# Notify before deleting the script
echo "Script will be destroyed now."

# Delete the script itself
rm -- "$0"
