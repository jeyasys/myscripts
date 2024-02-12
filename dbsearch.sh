#!/bin/bash

read -p "Enter the old domain without HTTP/HTTPS (e.g., domain.com): " OLD_DOMAIN
read -p "Enter the new domain without HTTP/HTTPS (e.g., abc.com): " NEW_DOMAIN

if ! command -v wp &> /dev/null
then
    echo "WP-CLI could not be found. Please install WP-CLI and run this script again."
    exit 1
fi

OLD_URL_HTTP="http://$OLD_DOMAIN"
OLD_URL_HTTPS="https://$OLD_DOMAIN"
OLD_URL_WWW_HTTP="http://www.$OLD_DOMAIN"
OLD_URL_WWW_HTTPS="https://www.$OLD_DOMAIN"
NEW_URL_HTTPS="https://$NEW_DOMAIN"

echo "To (New URL): $NEW_URL_HTTPS"
echo "From (Old URLs):"
echo

echo "- $OLD_URL_HTTPS"
wp search-replace "$OLD_URL_HTTPS" "$NEW_URL_HTTPS" --all-tables --precise --format=count

echo "- $OLD_URL_HTTP"
wp search-replace "$OLD_URL_HTTP" "$NEW_URL_HTTPS" --all-tables --precise --format=count

echo "- $OLD_URL_WWW_HTTPS"
wp search-replace "$OLD_URL_WWW_HTTPS" "$NEW_URL_HTTPS" --all-tables --precise --format=count

echo "- $OLD_URL_WWW_HTTP"
wp search-replace "$OLD_URL_WWW_HTTP" "$NEW_URL_HTTPS" --all-tables --precise --format=count

wp cache flush

echo "Search and replace completed."

rm -- "$0"
