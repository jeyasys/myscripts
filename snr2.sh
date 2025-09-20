#!/usr/bin/env bash
# Reliable path fixer + DB name scanner for Linux/BSD seds
# Replaces: /var/www/webroot/ROOT  -->  $(pwd)
# Edits only common text/code files; skips this script; shows summary; self-deletes.

set -Eeuo pipefail
IFS=$'\n'

# --- Identify this script (exclude & self-delete) ---
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
trap 'rm -f -- "$SCRIPT_PATH" >/dev/null 2>&1 || true' EXIT

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
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*"
                "$SCRIPT_NAME" )

# Allowed file extensions only
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

echo "=== DRY RUN: locating files that contain the old path ==="
echo "Command preview:"
echo "grep -rIlF ${GREP_EXCLUDES[*]} -- \"$OLD_PATH\" ."
echo

mapfile -t CANDIDATES < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)

TARGET_FILES=()
for f in "${CANDIDATES[@]}"; do
  is_allowed "$f" && TARGET_FILES+=( "$f" )
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
  echo "try:   sed -i 's#${OLD_PATH}#${NEW_PATH}#g' FILE"
  echo "or:    sed -i '' 's#${OLD_PATH}#${NEW_PATH}#g' FILE   (BSD sed)"
  echo "else:  sed 's#${OLD_PATH}#${NEW_PATH}#g' FILE > FILE.tmp && mv FILE.tmp FILE"
  echo
  read -rp "Proceed with replacements? (y/N): " CONFIRM
  echo
else
  echo "Nothing to replace. Skipping replacement step."
  CONFIRM="n"
fi

# --- Replace helpers ---
count_hits() { grep -F -o -- "$OLD_PATH" "$1" | wc -l | tr -d '[:space:]'; }

replace_one() {
  local f="$1" before after tmp rc=0
  before="$(count_hits "$f" || true)"

  if (( before == 0 )); then
    echo "  $f: 0 occurrence(s) — nothing to change"
    return 0
  fi

  # 1) GNU sed -i
  set +e
  sed -i 's#'"$OLD_PATH"'#'"$NEW_PATH"'#g' -- "$f"
  rc=$?
  set -e
  if (( rc == 0 )); then
    after="$(count_hits "$f" || true)"
    if (( after < before )); then
      echo "  $f: replaced $(( before - after )) occurrence(s) [gnu sed -i]"
      return 0
    fi
  fi

  # 2) BSD sed -i ''
  set +e
  sed -i '' 's#'"$OLD_PATH"'#'"$NEW_PATH"'#g' -- "$f"
  rc=$?
  set -e
  if (( rc == 0 )); then
    after="$(count_hits "$f" || true)"
    if (( after < before )); then
      echo "  $f: replaced $(( before - after )) occurrence(s) [bsd sed -i '']"
      return 0
    fi
  fi

  # 3) Safe temp write + mv
  tmp="${f}.tmp.$$"
  if sed 's#'"$OLD_PATH"'#'"$NEW_PATH"'#g' -- "$f" > "$tmp"; then
    if ! cmp -s -- "$f" "$tmp"; then
      mv -f -- "$tmp" "$f"
      after="$(count_hits "$f" || true)"
      echo "  $f: replaced $(( before - after )) occurrence(s) [temp+mv]"
      return 0
    else
      rm -f -- "$tmp" || true
    fi
  fi

  echo "  WARNING: $f did not change (before=$before)" >&2
  return 1
}

CHANGED_COUNT=0
BACKUP_COUNT=0
MODIFIED_FILES=()
UNTOUCHED_FILES=()

if [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]]; then
  for f in "${TARGET_FILES[@]}"; do
    cp -a -- "$f" "${f}_bkp-${STAMP}"
    ((BACKUP_COUNT++))
    if replace_one "$f"; then
      ((CHANGED_COUNT++))
      MODIFIED_FILES+=( "$f" )
    else
      UNTOUCHED_FILES+=( "$f" )
    fi
  done
  echo "Replacement pass completed."
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
  for f in "${MODIFIED_FILES[@]}"; do echo "  MODIFIED: $f"; done
fi
if ((${#UNTOUCHED_FILES[@]} > 0)); then
  for f in "${UNTOUCHED_FILES[@]}"; do echo "  UNCHANGED: $f"; done
fi
echo "DB name searched:         $DBNAME"
echo "DB hits:                  ${#DB_HITS[@]}"
echo "Old path residual count:  ${#RESIDUAL[@]}"
