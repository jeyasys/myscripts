#!/bin/bash

read -p "Enter the old directory path: " old_path

new_path="/var/www/webroot/ROOT"

if [[ -z "$old_path" ]]; then
    echo "You must provide an old directory path."
    exit 1
fi

echo "The script will run the following command:"
echo "wp search-replace \"$old_path\" \"$new_path\" --all-tables --precise"

read -p "Are you sure you want to proceed? (Y/N): " confirmation

confirmation=${confirmation^^}

if [[ "$confirmation" == "Y" ]]; then

    wp search-replace "$old_path" "$new_path" --all-tables --precise

    if [ $? -eq 0 ]; then
        echo "Search and replace completed successfully."
    else
        echo "There was an error performing the search and replace."
    fi
else
    echo "Operation cancelled."
fi

echo "Script will be destroyed now."

rm -- "$0"
