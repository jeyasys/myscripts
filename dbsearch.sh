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
RECORDS_HTTPS=$(wp search-replace --all-tables --report-changed-only "$OLD_URL_HTTPS" "$NEW_URL_HTTPS" --precise --quiet --skip-columns=guid)
RECORDS_HTTP=$(wp search-replace --all-tables --report-changed-only "$OLD_URL_HTTP" "$NEW_URL_HTTPS" --precise --quiet --skip-columns=guid)
RECORDS_WWW_HTTPS=$(wp search-replace --all-tables --report-changed-only "$OLD_URL_WWW_HTTPS" "$NEW_URL_HTTPS" --precise --quiet --skip-columns=guid)
RECORDS_WWW_HTTP=$(wp search-replace --all-tables --report-changed-only "$OLD_URL_WWW_HTTP" "$NEW_URL_HTTPS" --precise --quiet --skip-columns=guid)

# Output the summary table
echo "Search and replace summary:"
printf "%-40s %-40s %-10s\n" "Old URL" "New URL" "Records Updated"
printf "%-40s %-40s %-10s\n" "$OLD_URL_HTTPS" "$NEW_URL_HTTPS" "$RECORDS_HTTPS"
printf "%-40s %-40s %-10s\n" "$OLD_URL_WWW_HTTPS" "$NEW_URL_HTTPS" "$RECORDS_WWW_HTTPS"
printf "%-40s %-40s %-10s\n" "$OLD_URL_HTTP" "$NEW_URL_HTTPS" "$RECORDS_HTTP"
printf "%-40s %-40s %-10s\n" "$OLD_URL_WWW_HTTP" "$NEW_URL_HTTPS" "$RECORDS_WWW_HTTP"

echo "Search and replace completed."
