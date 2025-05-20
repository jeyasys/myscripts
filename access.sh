#!/bin/bash

SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"


mapfile -t user_array < <(
  rapyd site list --format json |
  jq -r '.[] | select(.user | test("^web_")) | "\(.user | gsub(" "; ""))|\(.webroot | gsub(" "; ""))|\(.domain)"'
)

if [ ${#user_array[@]} -eq 0 ]; then
  echo "No web_* users found."
  rm -f -- "$SCRIPT_PATH"
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

  sudo -u "$selected_user" -i bash -c "cd '$user_webroot'; bash"
 rm -f -- "$SCRIPT_PATH"
  find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'access.sh*' -delete
else
  echo "Invalid selection."
  rm -f -- "$SCRIPT_PATH"
  find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'access.sh*' -delete
fi
