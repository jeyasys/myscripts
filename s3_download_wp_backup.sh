#!/bin/bash
set -euo pipefail

DEST_DIR="/home/web_site3/web/www/app/public/s3"
AWS_REGION="us-east-1"
S3_BUCKET="staging-site-backups-useast"
SITE_URL="stg-xxxxxxxx.cloud"

if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone not found. Install it: sudo dnf install -y rclone"
  exit 1
fi

read -rp "AWS Access Key ID: " AWS_ACCESS_KEY
read -srp "AWS Secret Access Key: " AWS_SECRET_KEY; echo

AWS_ACCESS_KEY="$(printf "%s" "$AWS_ACCESS_KEY" | tr -d '\r\n')"
AWS_SECRET_KEY="$(printf "%s" "$AWS_SECRET_KEY" | tr -d '\r\n')"

if [[ -z "$AWS_ACCESS_KEY" || -z "$AWS_SECRET_KEY" ]]; then
  echo "Access key and secret key are required."; exit 1
fi

mkdir -p "$DEST_DIR"

SRC_PREFIX=":s3,provider=AWS,env_auth=false,access_key_id=${AWS_ACCESS_KEY},secret_access_key=${AWS_SECRET_KEY},region=${AWS_REGION},location_constraint=${AWS_REGION}"

echo "[*] Listing s3://${S3_BUCKET}/${SITE_URL}/"
rclone lsl "${SRC_PREFIX}:${S3_BUCKET}/${SITE_URL}/" || true

echo "[*] Downloading stg-db-export.sql..."
rclone copy "${SRC_PREFIX}:${S3_BUCKET}/${SITE_URL}/stg-db-export.sql" "$DEST_DIR" --progress --s3-no-check-bucket

echo "[*] Downloading ROOT.tar.gz..."
rclone copy "${SRC_PREFIX}:${S3_BUCKET}/${SITE_URL}/ROOT.tar.gz" "$DEST_DIR" --progress --s3-no-check-bucket

echo "[*] Verifying local files:"
ls -lh "$DEST_DIR/stg-db-export.sql" "$DEST_DIR/ROOT.tar.gz"

echo "[OK] Download complete → $DEST_DIR"
