#!/bin/bash
set -euo pipefail

# --- minimal colors ---
GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

# --- defaults you can just press Enter to accept ---
DEFAULT_REGION="us-east-1"
DEFAULT_BUCKET="staging-site-backups-useast"
DEFAULT_PREFIX="stg-wemake-736.ue1.rapydapps.cloud"   # S3 "folder" used in your backup
DEFAULT_DEST="/home/web_site3/web/www/app/public/s3"

read -rp "AWS Access Key ID: " AWS_ACCESS_KEY
read -srp "AWS Secret Access Key: " AWS_SECRET_KEY; echo
read -rp "AWS Region [${DEFAULT_REGION}]: " AWS_REGION; AWS_REGION="${AWS_REGION:-$DEFAULT_REGION}"
read -rp "S3 Bucket [${DEFAULT_BUCKET}]: " S3_BUCKET; S3_BUCKET="${S3_BUCKET:-$DEFAULT_BUCKET}"
read -rp "S3 Prefix (site folder) [${DEFAULT_PREFIX}]: " SITE_URL; SITE_URL="${SITE_URL:-$DEFAULT_PREFIX}"
read -rp "Local download directory [${DEFAULT_DEST}]: " DEST_DIR; DEST_DIR="${DEST_DIR:-$DEFAULT_DEST}"

echo -e "${BLUE}[*] Creating destination: ${DEST_DIR}${NC}"
mkdir -p "$DEST_DIR"

# unique, temporary remote to avoid clashes
REMOTE="myaws-$$"

echo -e "${BLUE}[*] Creating temporary rclone remote '${REMOTE}'...${NC}"
rclone config create "$REMOTE" s3 \
  provider AWS \
  env_auth false \
  access_key_id "$AWS_ACCESS_KEY" \
  secret_access_key "$AWS_SECRET_KEY" \
  region "$AWS_REGION" \
  location_constraint "$AWS_REGION" >/dev/null 2>&1

echo -e "${BLUE}[*] Listing s3://${S3_BUCKET}/${SITE_URL}/ ${NC}"
rclone lsl "${REMOTE}:${S3_BUCKET}/${SITE_URL}/" || true

echo -e "${BLUE}[*] Downloading stg-db-export.sql and ROOT.tar.gz...${NC}"
rclone copy "${REMOTE}:${S3_BUCKET}/${SITE_URL}/stg-db-export.sql" "$DEST_DIR" --progress --s3-no-check-bucket
rclone copy "${REMOTE}:${S3_BUCKET}/${SITE_URL}/ROOT.tar.gz"       "$DEST_DIR" --progress --s3-no-check-bucket

echo -e "${BLUE}[*] Verifying local files...${NC}"
ls -lh "$DEST_DIR/stg-db-export.sql" "$DEST_DIR/ROOT.tar.gz"

echo -e "${BLUE}[*] Removing temporary remote '${REMOTE}'...${NC}"
rclone config delete "$REMOTE" >/dev/null 2>&1 || true

echo -e "${GREEN}[OK] Download complete. Files in: ${DEST_DIR}${NC}"
