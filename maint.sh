#!/bin/bash

# Define the comment to be added
comment="/* That's all, stop editing! Happy publishing. */"

# Check if the line already exists in wp-config.php
if ! grep -Fxq "$comment" wp-config.php
then
    # Use awk to find the line number where 'require_once ABSPATH . 'wp-settings.php';' occurs
    line_num=$(awk '/require_once ABSPATH . '"'"'wp-settings.php'"'"';/{print NR}' wp-config.php)

    # If the line number is found, insert the comment two lines above it
    if [ ! -z "$line_num" ]; then
        let insert_line=line_num-1
        sed -i "${insert_line}i $comment" wp-config.php
    else
        echo "Could not find the appropriate place to insert the comment."
    fi
fi

# Check if the disable auto update block exists
if grep -q "define( 'AUTOMATIC_UPDATER_DISABLED', true );" wp-config.php; then
    echo "Auto-update is already disabled."
elif grep -q "define( 'AUTOMATIC_UPDATER_DISABLED', false );" wp-config.php; then
    # Replace false with true if it's set to false
    sed -i "s/define( 'AUTOMATIC_UPDATER_DISABLED', false );/define( 'AUTOMATIC_UPDATER_DISABLED', true );/g" wp-config.php
else
    # If the code block is missing, add it
    echo "/* Disable all site auto updates  */" >> wp-config.php
    echo "define( 'AUTOMATIC_UPDATER_DISABLED', true );" >> wp-config.php
fi

# Install the LiteSpeed Cache plugin
wp plugin install litespeed-cache

# Activate the LiteSpeed Cache plugin
wp plugin activate litespeed-cache

# Install the Flush Opcache plugin
wp plugin install flush-opcache

# Activate the Flush Opcache plugin
wp plugin activate flush-opcache

# Purge all caches in LiteSpeed
wp litespeed-purge all

# Flush the WordPress object cache
wp cache flush

# If you have Redis cache installed and want to flush it as well
wp redis flush

# Flush rewrite rules (resave permalinks)
wp rewrite flush --hard

# Delete the script itself
rm -- "$0"
