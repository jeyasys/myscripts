#!/usr/bin/env bash
# Ultra-verbose replacer: /var/www/webroot/ROOT -> $(pwd)
# Works on GNU sed (Linux). Adds heavy logging to diagnose any "no-change" cases.

set -Eeuo pipefail
IFS=$'\n'

# ====== Identify this script & self-delete on exit ======
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
trap 'echo "[INFO] Self-deleting $SCRIPT_PATH"; rm -f -- "$SCRIPT_PATH" >/dev/null 2>&1 || true' EXIT

# ====== Config ======
OLD_PATH="/var/www/webroot/ROOT"
STAMP="$(date +%F_%H%M%S)"
DOCROOT="$(pwd)"
NEW_PATH="$DOCROOT"

echo "=== ENV CHECKS ==="
echo "[INFO] PWD / DOCROOT: $DOCROOT"
echo "[INFO] sed version:"; sed --version 2>/dev/null | head -n1 || echo "[WARN] sed --version not available (non-GNU sed?)"
echo "[INFO] bash: $BASH_VERSION"
echo

# Show raw bytes to catch hidden chars (should be clean ASCII)
echo "[DEBUG] OLD_PATH bytes:"; printf '%s' "$OLD_PATH" | xxd -g1 -ps -c999 || true; echo
echo "[DEBUG] NEW_PATH bytes:"; printf '%s' "$NEW_PATH" | xxd -g1 -ps -c999 || true; echo

read -rp "Enter the database name to search for (e.g., wp_dbname): " DBNAME
echo

# ====== File selection ======
EXCLUDE_DIRS=( ".git" "node_modules" "vendor" "wp-content/uploads/wc-logs" )
EXCLUDE_FILES=( "*.log" "*.sql" "*.gz" "*.zip" "*.tar" "*.tar.gz" "*.tgz" "*_bkp-*" "$SCRIPT_NAME" )

ALLOWED_EXTS=( php php5 php7 phtml inc ini conf cnf env htaccess "user.ini" txt )

is_allowed() {
  local f="$1" base ext
  base="$(basename -- "$f")"
  [[ "$base" == ".htaccess" || "$base" == ".user.ini" || "$base" == "user.ini" ]] && return 0
  ext="${base##*.}"
  for e in "${ALLOWED_EXTS[@]}"; do [[ "$ext" == "$e" ]] && return 0; done
  return 1
}

GREP_EXCLUDES=()
for d in "${EXCLUDE_DIRS[@]}";  do GREP_EXCLUDES+=( "--exclude-dir=$d" ); done
for f in "${EXCLUDE_FILES[@]}";  do GREP_EXCLUDES+=( "--exclude=$f" );  done

echo "=== DRY RUN: locate files with OLD_PATH ==="
echo "[CMD] grep -rIlF ${GREP_EXCLUDES[*]} -- \"$OLD_PATH\" ."
mapfile -t CANDIDATES < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)
TARGET_FILES=()
for f in "${CANDIDATES[@]}"; do is_allowed "$f" && TARGET_FILES+=( "$f" ); done

if ((${#TARGET_FILES[@]} == 0)); then
  echo "[INFO] No eligible files contain: $OLD_PATH"
else
  echo "[INFO] Files to modify:"
  for f in "${TARGET_FILES[@]}"; do echo "  $f"; done
fi
echo

echo "=== DRY RUN: DB name search (no replace) ==="
echo "[CMD] grep -rIlF ${GREP_EXCLUDES[*]} -- \"$DBNAME\" ."
mapfile -t DB_HITS < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$DBNAME" . || true)
if ((${#DB_HITS[@]} == 0)); then
  echo "[INFO] No files contain DB name: $DBNAME"
else
  echo "[INFO] Files mentioning \"$DBNAME\":"
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
  echo "[INFO] Nothing to replace. Skipping."
  CONFIRM="n"
fi

count_hits() { grep -F -o -- "$OLD_PATH" "$1" | wc -l | tr -d '[:space:]'; }
preview_hits() {
  # print up to 3 lines containing OLD_PATH for eyeballing
  grep -nF -- "$OLD_PATH" "$1" | head -n 10 || true
}

CHANGED_COUNT=0
BACKUP_COUNT=0
MODIFIED_FILES=()
FAILED_FILES=()

if [[ "${CONFIRM:-n}" =~ ^[Yy]$ ]]; then
  echo "=== REPLACEMENT START ==="
  for f in "${TARGET_FILES[@]}"; do
    echo "[FILE] $f"
    before="$(count_hits "$f" || true)"
    echo "  [BEFORE] hits: $before"
    if (( before > 0 )); then
      echo "  [PREVIEW] lines with OLD_PATH (up to 10):"
      preview_hits "$f" | sed 's/^/    > /'
    fi

    echo "  [BACKUP] cp -a -- \"$f\" \"${f}_bkp-${STAMP}\""
    cp -a -- "$f" "${f}_bkp-${STAMP}" && ((BACKUP_COUNT++)) || echo "  [WARN] backup failed (continuing)"

    echo "  [RUN] sed -i 's#${OLD_PATH}#${NEW_PATH}#g' -- \"$f\""
    set +e
    sed -i 's#'"$OLD_PATH"'#'"$NEW_PATH"'#g' -- "$f"
    rc=$?
    set -e
    echo "  [SED RC] $rc"

    after="$(count_hits "$f" || true)"
    echo "  [AFTER] hits:  $after"

    if (( rc == 0 )) && (( after < before )); then
      echo "  [OK] Replaced $(( before - after )) occurrence(s)"
      ((CHANGED_COUNT++))
      MODIFIED_FILES+=( "$f" )
    else
      echo "  [FAIL] No change detected; dumping diff (first 10 lines if any):"
      set +e
      diff -u -- "${f}_bkp-${STAMP}" "$f" | head -n 40 || true
      set -e
      FAILED_FILES+=( "$f" )
    fi
    echo
  done
  echo "=== REPLACEMENT END ==="
  echo
else
  echo "[INFO] Replacement aborted by user."
  echo
fi

echo "=== POST-CHECK: residual OLD_PATH ==="
mapfile -t RESIDUAL < <(grep -rIlF "${GREP_EXCLUDES[@]}" -- "$OLD_PATH" . || true)
if ((${#RESIDUAL[@]} == 0)); then
  echo "[INFO] No remaining occurrences of $OLD_PATH"
else
  echo "[WARN] Still found references to $OLD_PATH in:"
  for f in "${RESIDUAL[@]}"; do echo "  $f"; done
fi
echo

echo "=== SUMMARY ==="
echo "NEW_PATH used:            $NEW_PATH"
echo "Backups created:          $BACKUP_COUNT (suffix: _bkp-$STAMP)"
echo "Files modified (OK):      $CHANGED_COUNT"
if ((${#MODIFIED_FILES[@]} > 0)); then
  for f in "${MODIFIED_FILES[@]}"; do echo "  [OK] $f"; done
fi
if ((${#FAILED_FILES[@]} > 0)); then
  echo "Files with NO CHANGE (investigate):"
  for f in "${FAILED_FILES[@]}"; do echo "  [NO-CHANGE] $f"; done
fi
echo "DB name searched:         $DBNAME"
echo "DB hits:                  ${#DB_HITS[@]}"
echo "Residual OLD_PATH count:  ${#RESIDUAL[@]}"
