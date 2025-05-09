#!/bin/bash

# Prompt for old path
read -p "Enter the old directory path: " old_path

# Prompt for new path
read -p "Enter the new directory path: " new_path

# Validate input
if [[ -z "$old_path" || -z "$new_path" ]]; then
    echo "You must provide both old and new directory paths."
    exit 1
fi

# Show intended command
echo "The script will run the following command:"
echo "wp search-replace \"$old_path\" \"$new_path\" --all-tables --precise"

# Ask for confirmation
read -p "Are you sure you want to proceed? (Y/N): " confirmation
confirmation=${confirmation^^}  # Convert to uppercase

# Proceed if confirmed
if [[ "$confirmation" == "Y" ]]; then

    wp search-replace "$old_path" "$new_path" --all-tables --precise

    if [ $? -eq 0 ]; then
        echo "Search and replace completed successfully."

        wp cache flush
        if [ $? -eq 0 ]; then
            echo "WordPress cache flushed successfully."
        else
            echo "Failed to flush WordPress cache."
        fi

    else
        echo "There was an error performing the search and replace."
    fi
else
    echo "Operation cancelled."
fi

echo "Script will be destroyed now."

rm -- "$0"
