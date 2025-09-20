#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n'

# --- CONFIG ---
OLD_PATH="/var/www/webroot/ROOT"
STAMP="$(date +%F_%H%M%S)"

# Grep exclusions: skip logs, SQL dumps, compressed/binary, and our own backups
EXCLUDE_DIRS=( ".git" "node_modules" "vendor" "wp-content/uploads/wc-logs" )
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*")

# --- DERIVED ---
DOCROOT="$(pwd)"
NEW_PATH="$DOCROOT"

echo "Detected docroot (pwd): $DOCROOT"
echo

# Prompt for DB name (to search only; no replacement)
read -rp "Enter the database name to search for (e.g., wp_dbname): " DBNAME
echo

# Build grep exclude args
GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}";  do GREP_EXCLUDES+=( "--exclude-dir=$d" ); done
for f in "${EXCLUDE_FILES[@]}";  do GREP_EXCLUDES+=( "--exclude=$f" );  done

echo "=== DRY RUN: locating files that contain the old path ==="
echo "Command preview:"
echo "grep -Irl \"$OLD_PATH\" . ${GREP_EXCLUDES[*]}"
echo

# Find files that will change
mapfile -t TARGET_FILES < <(grep -Irl "$OLD_PATH" . "${GREP_EXCLUDES[@]}" || true)

if ((${#TARGET_FILES[@]} == 0)); then
  echo "No files contain: $OLD_PATH"
else
  echo "The following files contain the old path and would be modified:"
  for f in "${TARGET_FILES[@]}"; do echo "  $f"; done
fi
echo

echo "=== DB search (no changes) — DRY RUN ==="
echo "Command preview:"
echo "grep -Irl \"$DBNAME\" . ${GREP_EXCLUDES[*]}"
echo

mapfile -t DB_HITS < <(grep -Irl "$DBNAME" . "${GREP_EXCLUDES[@]}" || true)
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
    # Backup
    cp -a -- "$f" "${f}_bkp-${STAMP}"
    ((BACKUP_COUNT++))
    # Replace
    sed -i "s#${OLD_PATH}#${NEW_PATH}#g" -- "$f"
    ((CHANGED_COUNT++))
  done
  echo "Replacement completed."
  echo
else
  echo "Replacement aborted by user."
  echo
fi

echo "=== Post-check: residual occurrences of old path (excluding backups) ==="
mapfile -t RESIDUAL < <(grep -Irl "$OLD_PATH" . "${GREP_EXCLUDES[@]}" || true)
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
  for f in "${DB_HITS[@]}"; do echo "  $f"; endone
fi
echo

echo "=== SUMMARY ==="
echo "Docroot used as NEW_PATH: $NEW_PATH"
echo "Backups created:          $BACKUP_COUNT (suffix: _bkp-$STAMP)"
echo "Files modified:           $CHANGED_COUNT"
echo "Old path residual count:  ${#RESIDUAL[@]}"
echo "DB name searched:         $DBNAME"
echo "DB hits:                  ${#DB_HITS[@]}"
