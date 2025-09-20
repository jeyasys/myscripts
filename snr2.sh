#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n'

SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
trap 'rm -f -- "$SCRIPT_PATH" >/dev/null 2>&1 || true' EXIT

OLD_PATH="/var/www/webroot/ROOT"
STAMP="$(date +%F_%H%M%S)"
NEW_PATH="$(pwd)"

echo "Detected docroot: $NEW_PATH"
echo
read -rp "Enter the database name to search for (e.g., wp_dbname): " DBNAME
echo

EXCLUDE_DIRS=( ".git" "node_modules" "vendor" "wp-content/uploads/wc-logs" )
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*" "$SCRIPT_NAME" )
ALLOWED_EXTS=( php php5 php7 phtml inc ini conf cnf env htaccess "user.ini" txt )

is_allowed() {
  local f="$1" b e
  b="$(basename -- "$f")"
  [[ "$b" == ".htaccess" || "$b" == ".user.ini" || "$b" == "user.ini" ]] && return 0
  e="${b##*.}"
  for x in "${ALLOWED_EXTS[@]}"; do [[ "$e" == "$x" ]] && return 0; done
  return 1
}

GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}";  do GREP_EXCLUDES+=( "--exclude-dir=$d" ); done
for f in "${EXCLUDE_FILES[@]}";  do GREP_EXCLUDES+=( "--exclude=$f" );  done

echo "=== DRY RUN: files with old path ==="
mapfile -t CANDS < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)
TARGET_FILES=(); for f in "${CANDS[@]}"; do is_allowed "$f" && TARGET_FILES+=( "$f" ); done
((${#TARGET_FILES[@]})) && printf '  %s\n' "${TARGET_FILES[@]}" || echo "  (none)"
echo

echo "=== DB search (no replace) ==="
mapfile -t DB_HITS < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$DBNAME" . || true)
((${#DB_HITS[@]})) && printf '  %s\n' "${DB_HITS[@]}" || echo "  (none)"
echo

if ((${#TARGET_FILES[@]})); then
  echo "Will run per file:"
  echo "cp -a FILE FILE_bkp-$STAMP"
  echo "sed -i 's#${OLD_PATH}#${NEW_PATH}#g' FILE"
  read -rp "Proceed with replacements? (y/N): " CONFIRM
  echo
else
  CONFIRM="n"
fi

count_hits() {
  (grep -F -o -- "$OLD_PATH" "$1" 2>/dev/null | wc -l | tr -d '[:space:]') || echo 0
}

CHANGED=0
BACKUPS=0
MODIFIED=()
UNCHANGED=()

if [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]]; then
  for f in "${TARGET_FILES[@]}"; do
    before="$(count_hits "$f")"
    cp -a -- "$f" "${f}_bkp-${STAMP}" 2>/dev/null || true
    [[ -f "${f}_bkp-${STAMP}" ]] && ((BACKUPS++))
    sed -i 's#'"$OLD_PATH"'#'"$NEW_PATH"'#g' -- "$f"
    after="$(count_hits "$f")"
    if (( after < before )); then
      ((CHANGED++)); MODIFIED+=( "$f" )
    else
      UNCHANGED+=( "$f" )
    fi
  done
fi

echo "=== Post-check: residual old path ==="
mapfile -t RESIDUAL < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)
((${#RESIDUAL[@]})) && printf '  %s\n' "${RESIDUAL[@]}" || echo "  (none)"
echo

echo "=== SUMMARY ==="
echo "New path:                $NEW_PATH"
echo "Backups created:         $BACKUPS (suffix: _bkp-$STAMP)"
echo "Files modified:          $CHANGED"
((${#MODIFIED[@]}))  && printf '  MODIFIED: %s\n'   "${MODIFIED[@]}"
((${#UNCHANGED[@]})) && printf '  UNCHANGED: %s\n'  "${UNCHANGED[@]}"
echo "DB name searched:        $DBNAME"
echo "DB hits:                 ${#DB_HITS[@]}"
echo "Residual old-path count: ${#RESIDUAL[@]}"
