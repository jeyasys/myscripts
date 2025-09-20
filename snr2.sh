#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n'

# Self-delete on any exit (success or error)
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
trap 'rm -f -- "$SCRIPT_PATH" >/dev/null 2>&1 || true' EXIT

OLD_PATH="/var/www/webroot/ROOT"
STAMP="$(date +%F_%H%M%S)"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

# Exclusions: noisy dirs/files + this script + its variants/backups
EXCLUDE_DIRS=( ".git" "node_modules" "vendor" "wp-content/uploads/wc-logs" )
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*"
                "$SCRIPT_NAME" "${SCRIPT_NAME}*" )

DOCROOT="$(pwd)"
NEW_PATH="$DOCROOT"

echo "Detected docroot (pwd): $DOCROOT"
echo

read -rp "Enter the database name to search for (e.g., wp_dbname): " DBNAME
echo

# Build grep exclude args (must come BEFORE pattern/path)
GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}";  do GREP_EXCLUDES+=( "--exclude-dir=$d" ); done
for f in "${EXCLUDE_FILES[@]}";  do GREP_EXCLUDES+=( "--exclude=$f" );  done
EXCLUDES_STR="$(printf '%q ' "${GREP_EXCLUDES[@]}")"

echo "=== DRY RUN: locating files that contain the old path ==="
echo "Command preview:"
echo "grep -rIlF ${EXCLUDES_STR} -- \"$OLD_PATH\" ."
echo

mapfile -t TARGET_FILES < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)

if ((${#TARGET_FILES[@]} == 0)); then
  echo "No files contain: $OLD_PATH"
else
  echo "The following files contain the old path and would be modified:"
  for f in "${TARGET_FILES[@]}"; do echo "  $f"; done
fi
echo

echo "=== DB search (no changes) — DRY RUN ==="
echo "Command preview:"
echo "grep -rIlF ${EXCLUDES_STR} -- \"$DBNAME\" ."
echo

mapfile -t DB_HITS < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$DBNAME" . || true)
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
  echo "For each file: cp -a FILE FILE_bkp-$STAMP && inplace_replace FILE"
  read -rp "Proceed with replacements? (y/N): " CONFIRM
  echo
else
  echo "Nothing to replace. Skipping replacement step."
  CONFIRM="n"
fi

CHANGED_COUNT=0
BACKUP_COUNT=0
MODIFIED_FILES=()

inplace_replace() {
  # Prefer perl for robust literal replacement; fallback to sed
  local file="$1"
  local rc=0

  # Count occurrences before
  local before=0 after=0
  before=$(grep -F -o -- "$OLD_PATH" "$file" | wc -l | tr -d '[:space:]' || true)

  if command -v perl >/dev/null 2>&1; then
    set +e
    perl -0777 -pe "s/\Q$OLD_PATH\E/$NEW_PATH/g" -i -- "$file"
    rc=$?
    set -e
  else
    # sed fallback; using an alternate delimiter
    set +e
    sed -i "s#${OLD_PATH}#${NEW_PATH}#g" -- "$file"
    rc=$?
    set -e
  fi

  if (( rc != 0 )); then
    echo "ERROR: Replacement failed for $file (rc=$rc)" >&2
    return "$rc"
  fi

  after=$(grep -F -o -- "$OLD_PATH" "$file" | wc -l | tr -d '[:space:]' || true)
  echo "  $file: replaced $(( before - after )) occurrence(s)"
  return 0
}

if [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]]; then
  for f in "${TARGET_FILES[@]}"; do
    cp -a -- "$f" "${f}_bkp-${STAMP}"
    ((BACKUP_COUNT++))
    if inplace_replace "$f"; then
      ((CHANGED_COUNT++))
      MODIFIED_FILES+=( "$f" )
    else
      echo "  Skipped due to error: $f"
    fi
  done
  echo "Replacement completed."
  echo
else
  echo "Replacement aborted by user."
  echo
fi

echo "=== Post-check: residual occurrences of old path (excluding backups & this script) ==="
mapfile -t RESIDUAL < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)
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
echo "Modified files:"
for f in "${MODIFIED_FILES[@]:-}"; do echo "  $f"; done
echo "Old path residual count:  ${#RESIDUAL[@]}"
echo "DB name searched:         $DBNAME"
echo "DB hits:                  ${#DB_HITS[@]}"
