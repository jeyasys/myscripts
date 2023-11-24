#!/bin/bash

# Prompt for the old and new domain
read -p "Enter the old domain without HTTP/HTTPS (e.g., domain.com): " OLD_DOMAIN
read -p "Enter the new domain without HTTP/HTTPS (e.g., abc.com): " NEW_DOMAIN

# Check if WP-CLI is available
if ! command -v wp &> /dev/null
then
    echo "WP-CLI could not be found. Please install WP-CLI and run this script again."
    exit 1
fi

# Define protocol versions of the URLs
OLD_URL_HTTP="http://$OLD_DOMAIN"
OLD_URL_HTTPS="https://$OLD_DOMAIN"
OLD_URL_WWW_HTTP="http://www.$OLD_DOMAIN"
OLD_URL_WWW_HTTPS="https://www.$OLD_DOMAIN"
NEW_URL_HTTPS="https://$NEW_DOMAIN"

# Run WP-CLI search-replace for database entries with HTTP and HTTPS
RECORDS_HTTPS=$(wp search-replace "$OLD_URL_HTTPS" "$NEW_URL_HTTPS" --all-tables --skip-columns=guid --quiet | grep -o '[0-9]\+' | head -1)
RECORDS_HTTP=$(wp search-replace "$OLD_URL_HTTP" "$NEW_URL_HTTPS" --all-tables --skip-columns=guid --quiet | grep -o '[0-9]\+' | head -1)
RECORDS_WWW_HTTPS=$(wp search-replace "$OLD_URL_WWW_HTTPS" "$NEW_URL_HTTPS" --all-tables --skip-columns=guid --quiet | grep -o '[0-9]\+' | head -1)
RECORDS_WWW_HTTP=$(wp search-replace "$OLD_URL_WWW_HTTP" "$NEW_URL_HTTPS" --all-tables --skip-columns=guid --quiet | grep -o '[0-9]\+' | head -1)

# Flush the WordPress cache
wp cache flush

# Output the summary in the desired format
echo "To (New URL): $NEW_URL_HTTPS"
echo "From (Old URLs):"
echo
echo "- $OLD_URL_HTTPS"
echo "$RECORDS_HTTPS"
echo
echo "- $OLD_URL_HTTP"
echo "$RECORDS_HTTP"
echo
echo "- $OLD_URL_WWW_HTTPS"
echo "$RECORDS_WWW_HTTPS"
echo
echo "- $OLD_URL_WWW_HTTP"
echo "$RECORDS_WWW_HTTP"
echo
echo "Search and replace completed."
# Delete the script file
rm -- "$0"
