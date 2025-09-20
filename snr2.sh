#!/usr/bin/env bash
# Simplified path fixer + DB name scanner
# Requires GNU grep + GNU sed (typical on Linux servers)

set -Eeuo pipefail
IFS=$'\n'

# --- CONFIG ---
OLD_PATH="/var/www/webroot/ROOT"
STAMP="$(date +%F_%H%M%S)"

# Identify this script (exclude + self-delete)
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
trap 'rm -f -- "$SCRIPT_PATH" >/dev/null 2>&1 || true' EXIT

# New path comes from current working directory (docroot)
DOCROOT="$(pwd)"
NEW_PATH="$DOCROOT"

echo "Detected docroot (pwd): $DOCROOT"
echo

# Ask DB name (search only)
read -rp "Enter the database name to search for (e.g., wp_dbname): " DBNAME
echo

# Exclusions
EXCLUDE_DIRS=( ".git" "node_modules" "vendor" "wp-content/uploads/wc-logs" )
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*"
                "$SCRIPT_NAME" )

# Allowed file extensions (keep it tight to avoid binaries)
ALLOWED_EXTS=( php php5 php7 phtml inc ini conf cnf env htaccess "user.ini" txt )

is_allowed() {
  local f="$1" base ext
  base="$(basename -- "$f")"
  # special cases without dot
  [[ "$base" == ".htaccess" || "$base" == ".user.ini" || "$base" == "user.ini" ]] && return 0
  # extract extension (after last dot)
  ext="${base##*.}"
  for e in "${ALLOWED_EXTS[@]}"; do
    [[ "$ext" == "$e" ]] && return 0
  done
  return 1
}

# Build grep exclude args (must come BEFORE pattern/path)
GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}";  do GREP_EXCLUDES+=( "--exclude-dir=$d" ); done
for f in "${EXCLUDE_FILES[@]}";  do GREP_EXCLUDES+=( "--exclude=$f" );  done

echo "=== DRY RUN: locating files that contain the old path ==="
echo "Command preview:"
echo "grep -rIlF ${GREP_EXCLUDES[*]} -- \"$OLD_PATH\" ."
echo

# Candidate text files containing OLD_PATH
mapfile -t CANDIDATES < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)

# Filter to allowed extensions
TARGET_FILES=()
for f in "${CANDIDATES[@]}"; do
  if is_allowed "$f"; then
    TARGET_FILES+=( "$f" )
  fi
done

if ((${#TARGET_FILES[@]} == 0)); then
  echo "No eligible files contain: $OLD_PATH"
else
  echo "These files would be modified:"
  for f in "${TARGET_FILES[@]}"; do echo "  $f"; done
fi
echo

echo "=== DB search (no changes) — DRY RUN ==="
echo "Command preview:"
echo "grep -rIlF ${GREP_EXCLUDES[*]} -- \"$DBNAME\" ."
echo
mapfile -t DB_HITS < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$DBNAME" . || true)
if ((${#DB_HITS[@]} == 0)); then
  echo "No files contain database name: $DBNAME"
else
  echo "Files mentioning \"$DBNAME\":"
  for f in "${DB_HITS[@]}"; do echo "  $f"; done
fi
echo

# Show EXACT commands that will run
if ((${#TARGET_FILES[@]} > 0)); then
  echo "=== Commands that will run per file ==="
  echo "cp -a FILE FILE_bkp-$STAMP"
  echo "sed -i 's#${OLD_PATH}#${NEW_PATH}#g' FILE"
  echo
  read -rp "Proceed with replacements? (y/N): " CONFIRM
  echo
else
  echo "Nothing to replace. Skipping replacement step."
  CONFIRM="n"
fi

CHANGED_COUNT=0
BACKUP_COUNT=0
MODIFIED_FILES=()

if [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]]; then
  for f in "${TARGET_FILES[@]}"; do
    # backup
    cp -a -- "$f" "${f}_bkp-${STAMP}"
    ((BACKUP_COUNT++))
    # replace (manual style)
    sed -i 's#'"$OLD_PATH"'#'"$NEW_PATH"'#g' -- "$f"
    ((CHANGED_COUNT++))
    MODIFIED_FILES+=( "$f" )
  done
  echo "Replacement completed."
  echo
else
  echo "Replacement aborted by user."
  echo
fi

echo "=== Post-check: residual occurrences of old path ==="
mapfile -t RESIDUAL < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)
if ((${#RESIDUAL[@]} == 0)); then
  echo "No remaining occurrences of $OLD_PATH (good)."
else
  echo "Still found references to $OLD_PATH in:"
  for f in "${RESIDUAL[@]}"; do echo "  $f"; done
fi
echo

echo "=== SUMMARY ==="
echo "Docroot (NEW_PATH):       $NEW_PATH"
echo "Backups created:          $BACKUP_COUNT (suffix: _bkp-$STAMP)"
echo "Files modified:           $CHANGED_COUNT"
if ((${#MODIFIED_FILES[@]} > 0)); then
  echo "Modified files:"
  for f in "${MODIFIED_FILES[@]}"; do echo "  $f"; done
fi
echo "DB name searched:         $DBNAME"
echo "DB hits:                  ${#DB_HITS[@]}"
echo "Old path residual count:  ${#RESIDUAL[@]}"
