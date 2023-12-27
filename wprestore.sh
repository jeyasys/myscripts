#!/bin/bash

backup_file=$(ls backup_*.tar.gz)
if [ -z "$backup_file" ]; then
    echo "Backup file not found."
    exit 1
fi

tar -xzvf "$backup_file"

if [ ! -f wp-config.php ]; then
    echo "wp-config.php not found."
    exit 1
fi

db_name=$(grep "DB_NAME" wp-config.php | cut -d "'" -f 4)
db_user=$(grep "DB_USER" wp-config.php | cut -d "'" -f 4)
db_password=$(grep "DB_PASSWORD" wp-config.php | cut -d "'" -f 4)
db_host=$(grep "DB_HOST" wp-config.php | cut -d "'" -f 4)

sql_backup_file=$(ls db_*.sql)
if [ -z "$sql_backup_file" ]; then
    echo "Database backup file not found."
    exit 1
fi

mysql -h "$db_host" -u "$db_user" -p"$db_password" "$db_name" < "$sql_backup_file"

if [ $? -eq 0 ]; then
    echo "Database restored successfully."
else
    echo "Failed to restore the database."
    exit 1
fi
