#!/bin/bash

user_lines=$(rapyd site list | awk -F'|' '
  NF > 5 && $5 ~ /web_/ {
    gsub(/^ +| +$/, "", $2);   # DOMAIN
    gsub(/^ +| +$/, "", $3);   # WEBROOT
    gsub(/ /, "", $5);         # USER
    print $5 "|" $3 "|" $2
  }' | sort -u)

IFS=$'\n' read -rd '' -a user_array <<<"$user_lines"

if [ ${#user_array[@]} -eq 0 ]; then
  echo "No users found."
  rm -- "$0"
  exit 1
fi

echo "Choose the user you'd like to login as:"
for i in "${!user_array[@]}"; do
  IFS='|' read -r user webroot domain <<<"${user_array[$i]}"
  echo "$((i + 1))) $user [$domain]"
done

read -rp "Enter number: " selection
selected_index=$((selection - 1))

if [[ $selection =~ ^[0-9]+$ ]] && (( selected_index >= 0 && selected_index < ${#user_array[@]} )); then
  IFS='|' read -r selected_user user_webroot user_domain <<<"${user_array[$selected_index]}"
  echo "Switching to user: $selected_user"
  sudo -u "$selected_user" -i bash -c "cd '$user_webroot' && exec bash"
else
  echo "Invalid selection."
fi

rm -- "$0"
