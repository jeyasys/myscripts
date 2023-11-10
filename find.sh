#!/bin/bash

# Prompt for the string to search, which can be a URL or a path
read -p "Enter the string to search for: " SEARCH_STRING

# Check if WP-CLI is available
if ! command -v wp &> /dev/null
then
    echo "WP-CLI could not be found. Please install WP-CLI and run this script again."
    exit 1
fi

# File where to log the results
LOG_FILE="checkurl.txt"

# Search the WordPress database for the string
echo "Searching the WordPress database for the string: $SEARCH_STRING"
echo "Database search results for string '$SEARCH_STRING':" > "$LOG_FILE"
wp db search "$SEARCH_STRING" --all-tables >> "$LOG_FILE"

# Find the string in the file system
echo "Searching the file system for the string: $SEARCH_STRING"
echo -e "\nFile system search results for string '$SEARCH_STRING':" >> "$LOG_FILE"
find . -type f \( -name "*.php" -o -name "*.js" -o -name "*.css" -o -name "*.html" \) -exec grep -Hn "$SEARCH_STRING" {} \; >> "$LOG_FILE"

echo "Search completed. Results have been saved to $LOG_FILE."
