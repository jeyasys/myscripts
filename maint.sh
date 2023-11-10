#!/bin/bash

# Check if the line "/* That's all, stop editing! Happy publishing. */" exists in wp-config.php
if ! grep -Fxq "/* That's all, stop editing! Happy publishing. */" wp-config.php
then
    # If the line doesn't exist, add it before the 'require_once(ABSPATH . 'wp-settings.php');' line
    sed -i "/require_once(ABSPATH . 'wp-settings.php');/i /* That's all, stop editing! Happy publishing. */" wp-config.php
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

# Install and activate the LiteSpeed Cache plugin
wp plugin install litespeed-cache --activate

# Install and activate the Flush Opcache plugin
wp plugin install flush-opcache --activate

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
