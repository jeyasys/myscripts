#!/bin/bash

# Set timezone to Singapore
export TZ=Asia/Singapore

# Define the backup script name
SCRIPTNAME="wpbackup.sh"

echo "Attempting database backup"

# Extract database credentials from wp-config.php
DB_USER=$(grep DB_USER wp-config.php | cut -d "'" -f 4)
DB_PASSWORD=$(grep DB_PASSWORD wp-config.php | cut -d "'" -f 4)
DB_NAME=$(grep DB_NAME wp-config.php | cut -d "'" -f 4)

# Format the current date and time
TIMESTAMP=$(date +"%Y%m%d%H%M%S")

# Backup the database
mysqldump -u $DB_USER -p$DB_PASSWORD $DB_NAME > db_$TIMESTAMP.sql

echo "Backing up database now"

# Check if the database backup was successful
if [ $? -eq 0 ]; then
    echo "Database backup complete"
else
    echo "Database backup failed"
    exit 1
fi

echo "Compressing files"

# Compress WordPress files and database dump, excluding the backup script
# The archive will be saved in the directory one level above
tar -czf ../backup_$TIMESTAMP.tar.gz --exclude=$SCRIPTNAME * db_$TIMESTAMP.sql

echo "Archive saved as backup_$TIMESTAMP.tar.gz in /var/www/webroot/"

# Notify before deleting the script
echo "Script will be destroyed now."

# Delete the script itself
rm -- "$0"
