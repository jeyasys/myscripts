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
if grep -q "define( 'AUTOMATIC_UPDATER_DISABLED', true );" wp-config.php; then
    echo "Auto-update is already disabled."
elif grep -q "define( 'AUTOMATIC_UPDATER_DISABLED', false );" wp-config.php; then
    # Replace false with true
    sed -i "s/define( 'AUTOMATIC_UPDATER_DISABLED', false );/define( 'AUTOMATIC_UPDATER_DISABLED', true );/g" wp-config.php
    echo "Auto-update was enabled, but now it's disabled."
else
    # Add the code block if missing
    echo "/* Disable all site auto updates  */" >> wp-config.php
    echo "define( 'AUTOMATIC_UPDATER_DISABLED', true );" >> wp-config.php
    echo "Auto update was not defined, it's disabled now."
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

#Set WordPress Site to Private Mode (Tick "Discourage search engines from indexing this site")
#wp option set blog_public 0

# Notify before deleting the script
echo "Script will be destroyed now."

# Delete the script itself
rm -- "$0"
