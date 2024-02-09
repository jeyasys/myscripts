#!/bin/bash

export TZ=Asia/Singapore

SCRIPTNAME="wpbackup.sh"

echo "Attempting database backup"

DB_USER=$(grep DB_USER wp-config.php | cut -d "'" -f 4)
DB_PASSWORD=$(grep DB_PASSWORD wp-config.php | cut -d "'" -f 4)
DB_NAME=$(grep DB_NAME wp-config.php | cut -d "'" -f 4)

TIMESTAMP=$(date +"%Y%m%d%H%M%S")

# Backup the database
mysqldump -u $DB_USER -p$DB_PASSWORD $DB_NAME > db_$TIMESTAMP.sql

echo "Backing up database now"

if [ $? -eq 0 ]; then
    echo "Database backup complete"
else
    echo "Database backup failed"
    exit 1
fi

echo "Compressing files"

# The archive will be saved in the directory one level above
tar -czf ../backup_$TIMESTAMP.tar.gz --exclude=$SCRIPTNAME * db_$TIMESTAMP.sql

echo "Archive saved as backup_$TIMESTAMP.tar.gz in /var/www/webroot/"

# After successfully creating the archive, delete the SQL file
rm db_$TIMESTAMP.sql
echo "Temporary database backup file db_$TIMESTAMP.sql deleted."

echo "Script will be destroyed now."

# Delete the script itself
rm -- "$0"
