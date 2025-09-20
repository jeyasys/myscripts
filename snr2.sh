#!/usr/bin/env bash
# snr2.sh
set -Eeuo pipefail
IFS=$'\n'

SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

OLD_PATH="/var/www/webroot/ROOT"
STAMP="$(date +%F_%H%M%S)"
DOCROOT="$(pwd)"
NEW_PATH="$DOCROOT"

echo "Detected docroot (pwd): $DOCROOT"
echo

read -rp "Enter the database name to search for (e.g., wp_dbname): " DBNAME
echo

# Exclusions
EXCLUDE_DIRS=( ".git" "node_modules" "vendor" "wp-content/uploads/wc-logs" )
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*" "$SCRIPT_NAME" )

# Allowed extensions (keeps it predictable)
ALLOWED_EXTS=( php php5 php7 phtml inc ini conf cnf env htaccess "user.ini" txt )

is_allowed() {
  local f="$1" base ext
  base="$(basename -- "$f")"
  [[ "$base" == ".htaccess" || "$base" == ".user.ini" || "$base" == "user.ini" ]] && return 0
  ext="${base##*.}"
  for e in "${ALLOWED_EXTS[@]}"; do [[ "$ext" == "$e" ]] && return 0; done
  return 1
}

# Build grep excludes BEFORE pattern/path
GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}";  do GREP_EXCLUDES+=( "--exclude-dir=$d" ); done
for f in "${EXCLUDE_FILES[@]}";  do GREP_EXCLUDES+=( "--exclude=$f" );  done

echo "=== DRY RUN: locating files with old path ==="
mapfile -t CANDIDATES < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)

TARGET_FILES=()
for f in "${CANDIDATES[@]}"; do is_allowed "$f" && TARGET_FILES+=( "$f" ); endone

if ((${#TARGET_FILES[@]} == 0)); then
  echo "No eligible files contain: $OLD_PATH"
else
  echo "These files would be modified:"
  for f in "${TARGET_FILES[@]}"; do echo "  $f"; done
fi
echo

echo "=== DB name search (no replacement) ==="
mapfile -t DB_HITS < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$DBNAME" . || true)
if ((${#DB_HITS[@]} == 0)); then
  echo "No files contain database name: $DBNAME"
else
  echo "Files mentioning \"$DBNAME\":"
  for f in "${DB_HITS[@]}"; do echo "  $f"; done
fi
echo

if ((${#TARGET_FILES[@]} > 0)); then
  echo "=== Commands per file ==="
  echo "cp -a FILE FILE_bkp-$STAMP"
  echo "sed -i 's#${OLD_PATH}#${NEW_PATH}#g' FILE"
  echo
  read -rp "Proceed with replacements? (y/N): " CONFIRM
  echo
else
  CONFIRM="n"
fi

count_hits(){ grep -F -o -- "$OLD_PATH" "$1" | wc -l | tr -d '[:space:]'; }

CHANGED_COUNT=0
BACKUP_COUNT=0
MODIFIED_FILES=()
UNCHANGED_FILES=()

if [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]]; then
  for f in "${TARGET_FILES[@]}"; do
    before="$(count_hits "$f" || true)"
    # Backup (quiet)
    cp -a -- "$f" "${f}_bkp-${STAMP}" 2>/dev/null || true
    [[ -f "${f}_bkp-${STAMP}" ]] && ((BACKUP_COUNT++))
    # Replace (exactly like your manual one-liner)
    sed -i 's#'"$OLD_PATH"'#'"$NEW_PATH"'#g' -- "$f"
    after="$(count_hits "$f" || true)"
    if (( after < before )); then
      ((CHANGED_COUNT++))
      MODIFIED_FILES+=( "$f" )
    else
      UNCHANGED_FILES+=( "$f" )
    fi
  done
fi

echo "=== Post-check: residual occurrences of old path ==="
mapfile -t RESIDUAL < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)
if ((${#RESIDUAL[@]} == 0)); then
  echo "No remaining references to $OLD_PATH"
else
  echo "Still found references in:"
  for f in "${RESIDUAL[@]}"; do echo "  $f"; done
fi
echo

echo "=== SUMMARY ==="
echo "NEW_PATH used:            $NEW_PATH"
echo "Backups created:          $BACKUP_COUNT (suffix: _bkp-$STAMP)"
echo "Files modified:           $CHANGED_COUNT"
if ((${#MODIFIED_FILES[@]} > 0)); then
  for f in "${MODIFIED_FILES[@]}"; do echo "  MODIFIED: $f"; done
fi
if ((${#UNCHANGED_FILES[@]} > 0)); then
  for f in "${UNCHANGED_FILES[@]}"; do echo "  UNCHANGED: $f"; done
fi
echo "DB name searched:         $DBNAME"
echo "DB hits:                  ${#DB_HITS[@]}"
echo "Residual old-path count:  ${#RESIDUAL[@]}"
echo
echo "Self-deleting: $SCRIPT_PATH"
rm -f -- "$SCRIPT_PATH" || true
