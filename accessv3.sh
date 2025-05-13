#!/bin/bash

if ! command -v gum &> /dev/null || [[ "$(gum --version)" != "gum version 0.13.0" ]]; then
  echo "Installing or upgrading gum to v0.13.0..."
  GUM_VERSION="0.13.0"
  ARCH="x86_64"
  OS="linux"
  TMP_DIR=$(mktemp -d)

  curl -sL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_${OS}_${ARCH}.tar.gz" -o "$TMP_DIR/gum.tar.gz"
  tar -xzf "$TMP_DIR/gum.tar.gz" -C "$TMP_DIR"
  chmod +x "$TMP_DIR/gum"

  if [ -w /usr/local/bin ]; then
    mv "$TMP_DIR/gum" /usr/local/bin/gum
  else
    sudo mv "$TMP_DIR/gum" /usr/bin/gum
  fi

  rm -rf "$TMP_DIR"
  echo "gum installed successfully."
fi

mapfile -t user_array < <(
  rapyd site list --format json |
  jq -r '.[] | select(.user | test("^web_")) | "\(.user | gsub(" "; ""))|\(.webroot | gsub(" "; ""))|\(.domain)"'
)

if [ ${#user_array[@]} -eq 0 ]; then
  echo "No web_* users found."
  rm -- "$0"
  exit 1
fi

menu_options=()
for i in "${!user_array[@]}"; do
  IFS='|' read -r user webroot domain <<<"${user_array[$i]}"
  menu_options+=("$i|$user [$domain]")
done

selection=$(printf "%s\n" "${menu_options[@]}" | gum choose --height=15 --header="Choose the user you'd like to log in as:")

if [[ -z "$selection" ]]; then
  echo "No selection made. Exiting."
  rm -- "$0"
  exit 1
fi

selected_index="${selection%%|*}"
IFS='|' read -r selected_user user_webroot user_domain <<<"${user_array[$selected_index]}"

gum confirm "Switch to user: $selected_user and enter directory: $user_webroot?" && \
sudo -u "$selected_user" -i bash -c "cd '$user_webroot' && exec bash"

rm -- "$0"
