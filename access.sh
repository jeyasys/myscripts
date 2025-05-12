#!/bin/bash

users=$(rapyd site list | awk -F'|' 'NF > 5 && $5 ~ /web_/ { gsub(/ /, "", $5); print $5 }' | sort -u)
IFS=$'\n' read -rd '' -a user_array <<<"$users"

if [ ${#user_array[@]} -eq 0 ]; then
  echo "No users found."
  rm -- "$0"
  exit 1
fi

echo "Choose the user you'd like to login as:"
select selected_user in "${user_array[@]}"; do
  if [[ -n "$selected_user" ]]; then
    echo "Switching to user: $selected_user"
    sudo -u "$selected_user" -i
    break
  else
    echo "Invalid selection. Try again."
  fi
done

rm -- "$0"
