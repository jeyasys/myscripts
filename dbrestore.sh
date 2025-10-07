#!/usr/bin/env bash
set -euo pipefail

# --- Self-delete helper (runs on any exit) ---
SELF_PATH="$(realpath "$0")"
cleanup_self() {
  echo "Deleting script: $SELF_PATH"
  rm -f "$SELF_PATH" || true
}
trap cleanup_self EXIT
trap cleanup_self INT TERM


WP_CONF="wp-config.php"

# Check wp-config.php exists in current dir
if [[ ! -f "$WP_CONF" ]]; then
  echo "Error: $WP_CONF not found in current directory ($(pwd))."
  echo "Make sure you run this script from the WordPress root where wp-config.php exists."
  exit 1
fi

# Helper to extract define('DB_NAME', 'value'); style lines robustly
extract_wp_define() {
  local key="$1"
  # Use grep to find line, then sed to extract value between quotes (single or double)
  local val
  val=$(grep -E "define\(\s*['\"]${key}['\"]" "$WP_CONF" \
    | sed -E "s/.*define\(\s*['\"]${key}['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/" \
    | tr -d '\r' || true)
  printf "%s" "$val"
}

DB_NAME=$(extract_wp_define "DB_NAME")
DB_USER=$(extract_wp_define "DB_USER")
DB_PASS=$(extract_wp_define "DB_PASSWORD")

# Basic checks
if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
  echo "Could not parse DB_NAME or DB_USER from $WP_CONF."
  echo "Parsed values:"
  echo "  DB_NAME: ${DB_NAME:-<empty>}"
  echo "  DB_USER: ${DB_USER:-<empty>}"
  exit 1
fi

# List .sql files in current dir (no recursion)
mapfile -t SQL_FILES < <(printf '%s\n' ./*.sql 2>/dev/null | sed 's#^\./##' )

# If glob didn't match, the literal "./*.sql" will be present; handle that
if [[ ${#SQL_FILES[@]} -eq 1 && "${SQL_FILES[0]}" == "./*.sql" ]]; then
  SQL_FILES=()
fi

if [[ ${#SQL_FILES[@]} -eq 0 ]]; then
  echo "No .sql files found in $(pwd). Place the SQL file(s) here and re-run."
  exit 1
fi

# If multiple, show menu
if [[ ${#SQL_FILES[@]} -gt 1 ]]; then
  echo "Multiple .sql files found in current directory. Choose one to restore:"
  for i in "${!SQL_FILES[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${SQL_FILES[i]}"
  done

  # Prompt for selection
  while true; do
    read -rp "Enter number (1-${#SQL_FILES[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SQL_FILES[@]} )); then
      SQLFILE="${SQL_FILES[choice-1]}"
      break
    else
      echo "Invalid selection. Try again."
    fi
  done
else
  SQLFILE="${SQL_FILES[0]}"
fi

# Hard-coded host as requested
DB_HOST="127.0.0.1"

# Build command string (showing --password='...' inline as requested)
# Note: exposing password on command line can be visible to other users while running.
MYSQL_CMD="mysql -h ${DB_HOST} -u ${DB_USER} --password='${DB_PASS}' ${DB_NAME} -f < \"${SQLFILE}\""

echo
echo "Found DB settings in ${WP_CONF}:"
echo "  DB_HOST: ${DB_HOST} (hard-coded)"
echo "  DB_USER: ${DB_USER}"
echo "  DB_NAME: ${DB_NAME}"
echo "Using SQL file: ${SQLFILE}"
echo
echo "Constructed restore command:"
echo
echo "  ${MYSQL_CMD}"
echo
read -rp "Proceed to run the command now? (y/N): " confirm
confirm=${confirm:-N}

# Run the command or abort
if [[ "$confirm" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  echo "Running restore..."
  eval "mysql -h '${DB_HOST}' -u '${DB_USER}' --password='${DB_PASS}' '${DB_NAME}' -f < \"${SQLFILE}\""
  exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo "Restore completed successfully."
  else
    echo "Restore finished with exit code $exit_code."
  fi
else
  echo "Aborted by user. No changes made."
fi

