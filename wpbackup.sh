#!/bin/bash

export TZ=Asia/Singapore

SCRIPTNAME=$(basename "$0")
CURRENT_DIR=$(pwd)
BACKUP_DIR=$(dirname "$CURRENT_DIR")

echo "Attempting database backup"

DB_USER=$(grep -E "define\s*\(\s*['\"]DB_USER['\"]" wp-config.php | cut -d "'" -f 4)
DB_PASSWORD=$(grep -E "define\s*\(\s*['\"]DB_PASSWORD['\"]" wp-config.php | cut -d "'" -f 4)
DB_NAME=$(grep -E "define\s*\(\s*['\"]DB_NAME['\"]" wp-config.php | cut -d "'" -f 4)
DB_HOST=$(grep -E "define\s*\(\s*['\"]DB_HOST['\"]" wp-config.php | cut -d "'" -f 4)

TIMESTAMP=$(date +"%Y%m%d%H%M%S")
SQL_FILE="db_${TIMESTAMP}.sql"
BACKUP_FILE="backup_${TIMESTAMP}.tar.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"

if [ -z "$DB_HOST" ]; then
    DB_HOST="localhost"
fi

# Force TCP if DB_HOST is localhost, because socket access may fail on shared hosting
if [ "$DB_HOST" = "localhost" ]; then
    MYSQL_HOST="127.0.0.1"
else
    MYSQL_HOST="$DB_HOST"
fi

echo "Backing up database now"

if mysqldump -h "$MYSQL_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$SQL_FILE"; then
    echo "Database backup complete"
else
    echo "Database backup failed"
    rm -f "$SQL_FILE"
    exit 1
fi

echo "Compressing files"

if tar \
    --exclude="./${SCRIPTNAME}" \
    -czf "$BACKUP_PATH" \
    .; then

    echo "Archive saved as: $BACKUP_PATH"
else
    echo "Archive creation failed"
    rm -f "$SQL_FILE"
    exit 1
fi

rm -f "$SQL_FILE"
echo "Temporary database backup file $SQL_FILE deleted."

echo "Script will be destroyed now."
rm -- "$0"
