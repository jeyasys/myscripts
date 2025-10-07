#!/usr/bin/env bash
set -euo pipefail

SELF_PATH="$(realpath "$0")"
cleanup_self() {
  echo "Deleting script: $SELF_PATH"
  rm -f "$SELF_PATH"
}
trap cleanup_self EXIT

mapfile -t SQL_FILES < <(printf '%s\n' ./*.sql 2>/dev/null | sed 's#^\./##')
if [[ ${#SQL_FILES[@]} -eq 1 && "${SQL_FILES[0]}" == "./*.sql" ]]; then
  SQL_FILES=()
fi

if [[ ${#SQL_FILES[@]} -eq 0 ]]; then
  echo "No .sql files found in $(pwd). Place the SQL file(s) here and re-run."
  exit 1
fi

if [[ ${#SQL_FILES[@]} -gt 1 ]]; then
  echo "Multiple .sql files found in current directory. Choose one to process:"
  for i in "${!SQL_FILES[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${SQL_FILES[i]}"
  done
  while true; do
    read -rp "Enter number (1-${#SQL_FILES[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SQL_FILES[@]} )); then
      INFILE="${SQL_FILES[choice-1]}"
      break
    else
      echo "Invalid selection. Try again."
    fi
  done
else
  INFILE="${SQL_FILES[0]}"
fi

basename_no_ext="${INFILE%.sql}"
next_out() {
  local n=2
  while :; do
    local candidate="${basename_no_ext}-v${n}.sql"
    [[ ! -e "$candidate" ]] && { printf "%s" "$candidate"; return; }
    ((n++))
  done
}
OUTFILE="$(next_out)"

SED_PREVIEW="sed -E -e 's/DEFINER=\`[^\\\`]+\`@\`[^\\\`]+\`/DEFINER=CURRENT_USER/g' -e 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g' '${INFILE}' > '${OUTFILE}'"

echo
echo "Input : ${INFILE}"
echo "Output: ${OUTFILE}"
echo
echo "The following command will be executed:"
echo
echo "  $SED_PREVIEW"
echo
read -rp "Proceed? (y/N): " confirm
confirm=${confirm:-N}

if [[ "$confirm" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  sed -E \
    -e 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' \
    -e 's/SQL SECURITY DEFINER/SQL SECURITY INVOKER/g' \
    "$INFILE" > "$OUTFILE"
  echo "Done. Wrote: $OUTFILE"
else
  echo "Aborted. No changes made."
fi
