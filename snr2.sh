#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n'

# --- CONFIG ---
OLD_PATH="/var/www/webroot/ROOT"
STAMP="$(date +%F_%H%M%S)"

# --- Identify this script (to exclude & self-delete) ---
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

# Exclusions: logs, dumps, archives, our backups, and THIS script
EXCLUDE_DIRS=( ".git" "node_modules" "vendor" "wp-content/uploads/wc-logs" )
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*"
                "$SCRIPT_NAME" )

# --- DERIVED ---
DOCROOT="$(pwd)"
NEW_PATH="$DOCROOT"

echo "Detected docroot (pwd): $DOCROOT"
echo

# DB name (search only)
read -rp "Enter the database name to search for (e.g., wp_dbname): " DBNAME
echo

# Build grep exclude args (must appear BEFORE pattern & path)
GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}";  do GREP_EXCLUDES+=( "--exclude-dir=$d" ); done
for f in "${EXCLUDE_FILES[@]}";  do GREP_EXCLUDES+=( "--exclude=$f" );  done
EXCLUDES_STR="$(printf '%s ' "${GREP_EXCLUDES[@]}")"

echo "=== DRY RUN: locating files that contain the old path ==="
echo "Command preview:"
echo "grep -Irl ${EXCLUDES_STR}-e \"$OLD_PATH\" ."
echo

# Options BEFORE -e pattern and path (important)
mapfile -t TARGET_FILES < <(grep -Irl ${GREP_EXCLUDES[@]} -e "$OLD_PATH" . || true)

if ((${#TARGET_FILES[@]} == 0)); then
  echo "No files contain: $OLD_PATH"
else
  echo "The following files contain the old path and would be modified:"
  for f in "${TARGET_FILES[@]}"; do echo "  $f"; done
fi
echo

echo "=== DB search (no changes) — DRY RUN ==="
echo "Command preview:"
echo "grep -Irl ${EXCLUDES_STR}-e \"$DBNAME\" ."
echo

mapfile -t DB_HITS < <(grep -Irl ${GREP_EXCLUDES[@]} -e "$DBNAME" . || true)
if ((${#DB_HITS[@]} == 0)); then
  echo "No files contain database name: $DBNAME"
else
  echo "Files mentioning \"$DBNAME\":"
  for f in "${DB_HITS[@]}"; do echo "  $f"; done
fi
echo

# Confirm execution
if ((${#TARGET_FILES[@]} > 0)); then
  echo "About to execute path replacement:"
  echo "For each file: cp -a FILE FILE_bkp-$STAMP && sed -i 's#${OLD_PATH}#${NEW_PATH}#g' FILE"
  read -rp "Proceed with replacements? (y/N): " CONFIRM
  echo
else
  echo "Nothing to replace. Skipping replacement step."
  CONFIRM="n"
fi

CHANGED_COUNT=0
BACKUP_COUNT=0

if [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]]; then
  for f in "${TARGET_FILES[@]}"; do
    cp -a -- "$f" "${f}_bkp-${STAMP}"
    ((BACKUP_COUNT++))
    sed -i "s#${OLD_PATH}#${NEW_PATH}#g" -- "$f"
    ((CHANGED_COUNT++))
  done
  echo "Replacement completed."
  echo
else
  echo "Replacement aborted by user."
  echo
fi

echo "=== Post-check: residual occurrences of old path (excluding backups & this script) ==="
mapfile -t RESIDUAL < <(grep -Irl ${GREP_EXCLUDES[@]} -e "$OLD_PATH" . || true)
if ((${#RESIDUAL[@]} == 0)); then
  echo "No remaining occurrences of $OLD_PATH (good)."
else
  echo "Still found references to $OLD_PATH in:"
  for f in "${RESIDUAL[@]}"; do echo "  $f"; done
fi
echo

echo "=== DB search (final) ==="
if ((${#DB_HITS[@]} == 0)); then
  echo "No files contain \"$DBNAME\"."
else
  echo "Files mentioning \"$DBNAME\":"
  for f in "${DB_HITS[@]}"; do echo "  $f"; done
fi
echo

echo "=== SUMMARY ==="
echo "Docroot used as NEW_PATH: $NEW_PATH"
echo "Backups created:          $BACKUP_COUNT (suffix: _bkp-$STAMP)"
echo "Files modified:           $CHANGED_COUNT"
echo "Old path residual count:  ${#RESIDUAL[@]}"
echo "DB name searched:         $DBNAME"
echo "DB hits:                  ${#DB_HITS[@]}"

# --- Self delete ---
echo
echo "Self-deleting script: $SCRIPT_PATH"
rm -f -- "$SCRIPT_PATH" || true
