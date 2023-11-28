#!/bin/bash

# Set the log file path with the specified format
LOG_FILE="rsync_$(date +"%Y%m%d%H%M%S").txt"

# Prompt for user input
read -p "1) Source server IP/hostname: " SOURCE_IP
read -p "2) Source server SSH username: " SSH_USER
read -p "3) Source server port (default is 22): " SSH_PORT
read -p "4) Source server file path: " SOURCE_PATH
read -p "5) Source server SSH password: " -s SSH_PASSWORD
echo    # Move to the next line after entering the password
read -p "6) Destination server path (press Enter for default): /var/www/webroot/ROOT/ " DEST_PATH
read -p "7) Enter the path to the private key (leave blank if none): " PRIVATE_KEY_PATH

# Default to port 22 if no port is specified
SSH_PORT=${SSH_PORT:-22}

# Prompt for excluding files/folders
EXCLUDE_STRING=""
while true; do
    read -p "8) Exclude files/folder (enter 'no' or 'n' to skip): " EXCLUDE_FILE
    if [ "$EXCLUDE_FILE" == "no" ] || [ "$EXCLUDE_FILE" == "n" ]; then
        break
    fi
    EXCLUDE_STRING="$EXCLUDE_STRING --exclude '$EXCLUDE_FILE'"
done

# Determine SSH command based on private key presence
if [ -n "$PRIVATE_KEY_PATH" ]; then
    SSH_COMMAND="ssh -i $PRIVATE_KEY_PATH -p $SSH_PORT"
else
    SSH_COMMAND="ssh -p $SSH_PORT"
fi

# Default destination path if not provided
DEST_PATH=${DEST_PATH:-"/var/www/webroot/ROOT/"}

# Display the rsync command to be executed
RSYNC_COMMAND="rsync -avzhe --progress --stats -e '$SSH_COMMAND' $EXCLUDE_STRING $SSH_USER@$SOURCE_IP:$SOURCE_PATH $DEST_PATH"

echo "Rsync Command: $RSYNC_COMMAND"

# Ask for confirmation
read -p "Do you want to proceed with this rsync command? (Y/N): " CONFIRMATION
if [ "$CONFIRMATION" == "Y" ] || [ "$CONFIRMATION" == "y" ]; then
    # Run the rsync command and log output
    echo "$SSH_PASSWORD" | $RSYNC_COMMAND > "$LOG_FILE" 2>&1
    echo "Rsync completed. Log file: $LOG_FILE"
else
    echo "Rsync operation aborted."
fi
