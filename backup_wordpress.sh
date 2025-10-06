#!/bin/bash

# WordPress S3 Backup Script (Simplified with rclone copy)
# Run as root: ./backup_wordpress.sh

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
AWS_ACCESS_KEY=""
AWS_SECRET_KEY=""
AWS_REGION=""
S3_BUCKET=""
WEBROOT=""
SITE_URL=""
DB_CHARSET=""
TEMP_FILES=""
WP_CLI="/home/litespeed/bin/wp"

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

prompt() {
    echo -e "${CYAN}$1${NC}"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# Function to read input with validation
read_input() {
    local prompt_text="$1"
    local variable_name="$2"
    local is_secret="${3:-false}"
    local validation_func="${4:-}"
    local allow_empty="${5:-false}"
    
    while true; do
        if [[ "$is_secret" == "true" ]]; then
            prompt "$prompt_text"
            read -s input
            echo  # Add newline after secret input
        else
            prompt "$prompt_text"
            read input
        fi
        
        if [[ -z "$input" ]] && [[ "$allow_empty" != "true" ]]; then
            error "This field cannot be empty. Please try again."
            continue
        fi
        
        # Run validation function if provided (only if input is not empty)
        if [[ -n "$input" ]] && [[ -n "$validation_func" ]] && ! $validation_func "$input"; then
            continue
        fi
        
        # Set the variable
        declare -g "$variable_name"="$input"
        break
    done
}

# Check if running in screen session
is_in_screen() {
    [[ -n "${STY:-}" ]] || [[ -n "${TMUX:-}" ]]
}

# Detect AWS region from site URL
detect_aws_region() {
    local url="$1"
    if [[ "$url" =~ ew1 ]]; then
        echo "eu-west-1"
    elif [[ "$url" =~ ue1 ]]; then
        echo "us-east-1"
    elif [[ "$url" =~ uw2 ]]; then
        echo "us-west-2"
    else
        echo "us-east-1"
    fi
}

# Get bucket name based on region
get_bucket_for_region() {
    case "$1" in
        eu-west-1) echo "staging-site-backups-euwest" ;;
        us-east-1) echo "staging-site-backups-useast" ;;
        us-west-2) echo "staging-site-backups-uswest" ;;
        *) echo "" ;;
    esac
}

# Get human-readable region name
get_region_name() {
    case "$1" in
        eu-west-1) echo "Europe (Ireland)" ;;
        us-east-1) echo "US East (N. Virginia)" ;;
        us-west-2) echo "US West (Oregon)" ;;
        *) echo "Unknown Region" ;;
    esac
}

# Select AWS region and bucket interactively
select_region_and_bucket() {
    local default_region="$1"
    local default_bucket
    default_bucket=$(get_bucket_for_region "$default_region")
    
    echo
    info "Available S3 Backup Locations:"
    echo "  1) Europe (Ireland) - eu-west-1 → staging-site-backups-euwest"
    echo "  2) US East (N. Virginia) - us-east-1 → staging-site-backups-useast"
    echo "  3) US West (Oregon) - us-west-2 → staging-site-backups-uswest"
    echo "  4) Custom (enter your own region and bucket)"
    echo
    
    if [[ -n "$default_region" ]] && [[ -n "$default_bucket" ]]; then
        prompt "Select backup location [detected: $(get_region_name $default_region) - Press Enter to accept]: "
    else
        prompt "Select backup location (1-4): "
    fi
    
    read region_input
    
    # If empty and default exists, use default
    if [[ -z "$region_input" ]] && [[ -n "$default_region" ]]; then
        AWS_REGION="$default_region"
        S3_BUCKET="$default_bucket"
        return
    fi
    
    case "$region_input" in
        1) AWS_REGION="eu-west-1"; S3_BUCKET="staging-site-backups-euwest" ;;
        2) AWS_REGION="us-east-1"; S3_BUCKET="staging-site-backups-useast" ;;
        3) AWS_REGION="us-west-2"; S3_BUCKET="staging-site-backups-uswest" ;;
        4)
            prompt "Enter custom AWS region (e.g., eu-west-1): "
            read custom_region
            if [[ ! "$custom_region" =~ ^[a-z]{2,3}-[a-z]+-[0-9]$ ]]; then
                error "Invalid region format. Using default: $default_region"
                AWS_REGION="$default_region"
                S3_BUCKET="$default_bucket"
            else
                AWS_REGION="$custom_region"
                read_input "Enter custom S3 bucket name: " "S3_BUCKET" "false" "validate_s3_bucket"
            fi
            ;;
        "")
            error "No selection made. Using default: $default_region"
            AWS_REGION="$default_region"
            S3_BUCKET="$default_bucket"
            ;;
        *)
            error "Invalid selection. Using default: $default_region"
            AWS_REGION="$default_region"
            S3_BUCKET="$default_bucket"
            ;;
    esac
}

# Validation functions
validate_s3_bucket() {
    local bucket="$1"
    if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9\-]*[a-z0-9]$ ]] || [[ ${#bucket} -lt 3 ]] || [[ ${#bucket} -gt 63 ]]; then
        error "Invalid S3 bucket name. Must be 3-63 chars, lowercase, numbers, hyphens only"
        return 1
    fi
    return 0
}

validate_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        error "Directory '$dir' does not exist"
        return 1
    fi
    return 0
}

check_disk_space() {
    log "Analyzing disk space requirements..."
    local root_size
    root_size=$(du -sb "$WEBROOT" 2>/dev/null | cut -f1 || echo "0")
    local db_size=0
    db_size=$("$WP_CLI" db size --allow-root --skip-plugins --skip-themes --size_format=b --quiet 2>/dev/null | grep -oP '^\d+' || echo "0")
    local total_size=$((root_size + db_size))
    local required_space=$((total_size * 110 / 100))
    local available_space
    available_space=$(df -B1 "$WEBROOT/../" | awk 'NR==2 {print $4}')
    
    echo
    info "=== Disk Space Analysis ==="
    echo "WordPress files size: $(numfmt --to=iec $root_size)"
    echo "Database size (est.): $(numfmt --to=iec $db_size)"
    echo "Total backup size: $(numfmt --to=iec $total_size)"
    echo "Required space (with 10% buffer): $(numfmt --to=iec $required_space)"
    echo "Available disk space: $(numfmt --to=iec $available_space)"
    echo
    
    local ten_gb=$((10 * 1024 * 1024 * 1024))
    if [[ $total_size -gt $ten_gb ]]; then
        warning "*** Large site detected (>10GB)!"
        if ! is_in_screen; then
            warning "You are NOT running in a screen/tmux session."
            warning "For large backups, it's recommended to run this in screen to prevent interruption."
            echo
            prompt "Do you want to continue anyway? (y/N): "
            read -r continue_anyway
            if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                error "Backup cancelled. Please run this script in a screen session:"
                error "  screen -S backup"
                error "  ./backup_wordpress.sh"
                exit 1
            fi
        else
            success "Running in screen/tmux session - good for large backups!"
        fi
    fi
    
    if [[ $available_space -lt $required_space ]]; then
        local needed=$((required_space - available_space))
        error "*** INSUFFICIENT DISK SPACE!"
        error "You need $(numfmt --to=iec $needed) more disk space to safely complete this backup."
        echo
        prompt "Do you want to continue anyway? (NOT RECOMMENDED) (y/N): "
        read -r force_continue
        if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
            exit 1
        fi
        warning "Continuing with insufficient space - backup may fail!"
    else
        success "Sufficient disk space available"
    fi
}

collect_configuration() {
    echo
    info "=== WordPress S3 Backup Configuration ==="
    echo
    
    info "WordPress Configuration:"
    read_input "Enter WordPress root directory path [/var/www/webroot/ROOT]: " "input" "false" "" "true"
    WEBROOT="${input:-/var/www/webroot/ROOT}"
    validate_directory "$WEBROOT" || exit 1
    
    log "Analyzing WordPress installation..."
    cd "$WEBROOT" || exit 1
    
    if ! "$WP_CLI" core is-installed --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null; then
        error "WordPress not installed in '$WEBROOT'"
        exit 1
    fi
    
    local detected_url
    detected_url=$("$WP_CLI" option get siteurl --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | sed 's|https\?://||')
    local detected_charset
    detected_charset=$("$WP_CLI" eval 'global $wpdb; echo $wpdb->charset . PHP_EOL;' --allow-root --skip-plugins --skip-themes --quiet 2>/dev/null | tr -d '\n')
    
    success "WordPress installation detected"
    echo
    
    local suggested_region
    suggested_region=$(detect_aws_region "$SITE_URL")
    local suggested_bucket
    suggested_bucket=$(get_bucket_for_region "$suggested_region")
    
    info "Detected WordPress Information:"
    echo "Site URL: $detected_url"
    echo "Database charset: $detected_charset"
    echo "Detected AWS Region: $(get_region_name $suggested_region) ($suggested_region)"
    echo "Suggested S3 Bucket: $suggested_bucket"
    echo
    
    prompt "Customize destination folder name? Press Enter to accept [Detected: $detected_url]: "
    read custom_url
    SITE_URL="${custom_url:-$detected_url}"
    
    prompt "Customize database charset? Press Enter to accept [Detected: $detected_charset]: "
    read custom_charset
    DB_CHARSET="${custom_charset:-$detected_charset}"
    
    echo
    suggested_region=$(detect_aws_region "$SITE_URL")
    
    info "AWS Configuration:"
    read_input "Enter AWS Access Key ID: " "AWS_ACCESS_KEY"
    read_input "Enter AWS Secret Access Key: " "AWS_SECRET_KEY" "true"
    select_region_and_bucket "$suggested_region"
    
    echo
    info "=== Configuration Summary ==="
    echo "WordPress Root: $WEBROOT"
    echo "Site URL: $SITE_URL"
    echo "Database charset: $DB_CHARSET"
    echo "AWS Region: $(get_region_name $AWS_REGION) ($AWS_REGION)"
    echo "S3 Bucket: $S3_BUCKET"
    echo
    
    prompt "Is this configuration correct? (Y/n): "
    read -r confirm
    if [[ -z "$confirm" ]] || [[ "$confirm" =~ ^[Yy]$ ]]; then
        success "Configuration confirmed"
    else
        error "Configuration cancelled by user"
        exit 1
    fi
}

cleanup() {
    echo
    log "Performing cleanup..."
    
    if rclone config show myaws >/dev/null 2>&1; then
        rclone config delete myaws
        success "Removed rclone configuration"
    fi
    
    if [[ -n "$TEMP_FILES" ]]; then
        cd "$WEBROOT/../" && rm -f $TEMP_FILES 2>/dev/null || true
        success "Removed temporary files: $TEMP_FILES"
    fi
    
    if command -v rclone &> /dev/null; then
        echo
        prompt "Remove rclone from system? (y/N): "
        read -r remove_rclone
        if [[ "$remove_rclone" =~ ^[Yy]$ ]]; then
            yum remove -y rclone
            success "Removed rclone from system"
        fi
    fi
    
    log "Cleanup completed"
}

trap cleanup EXIT

check_prerequisites() {
    log "Checking prerequisites..."
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
    
    if ! command -v yum &> /dev/null; then
        error "yum package manager not found"
        exit 1
    fi
    
    if [[ ! -f "$WP_CLI" ]]; then
        error "WP-CLI not found at $WP_CLI"
        exit 1
    fi
    
    if ! command -v mysqldump &> /dev/null; then
        error "mysqldump not found in PATH"
        exit 1
    fi
    
    success "Prerequisites check passed"
}

install_rclone() {
    log "Checking rclone installation..."
    if command -v rclone &> /dev/null; then
        success "rclone is already installed"
    else
        info "Installing rclone..."
        yum install -y rclone >/dev/null 2>&1
        success "rclone installed successfully"
    fi
}

setup_rclone() {
    log "Setting up rclone configuration..."
    
    rclone config create myaws s3 \
        provider AWS \
        env_auth false \
        access_key_id "$AWS_ACCESS_KEY" \
        secret_access_key "$AWS_SECRET_KEY" \
        region "$AWS_REGION" \
        location_constraint "$AWS_REGION" >/dev/null 2>&1
    
    info "Testing S3 connection..."
    if ! rclone lsd myaws:$S3_BUCKET >/dev/null 2>&1; then
        error "Failed to connect to S3 bucket '$S3_BUCKET'"
        error "Please check your AWS credentials and bucket name"
        exit 1
    fi
    success "S3 connection established successfully"
}

# --- CHANGED FUNCTION: now uses mysqldump instead of wp db export ---
export_database() {
    log "Exporting database (mysqldump)..."
    cd "$WEBROOT" || { error "Failed to access WordPress directory '$WEBROOT'"; exit 1; }

    local WP_CONF="wp-config.php"
    if [[ ! -f "$WP_CONF" ]]; then
        error "wp-config.php not found in $WEBROOT"
        exit 1
    fi

    extract_wp_define() {
        local key="$1"
        grep -E "define\(\s*['\"]${key}['\"]" "$WP_CONF" \
          | sed -E "s/.*define\(\s*['\"]${key}['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/" \
          | tr -d '\r' | head -n1
    }

    local DB_NAME DB_USER DB_PASSWORD DB_HOST
    DB_NAME=$(extract_wp_define "DB_NAME")
    DB_USER=$(extract_wp_define "DB_USER")
    DB_PASSWORD=$(extract_wp_define "DB_PASSWORD")
    DB_HOST=$(extract_wp_define "DB_HOST")
    if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_HOST" ]]; then
        error "Failed to read DB credentials from wp-config.php"
        exit 1
    fi

    # Build connection opts (host:port or socket)
    local HOST_OPT="" PORT_OPT="" SOCKET_OPT=""
    if [[ "$DB_HOST" == /* ]]; then
        SOCKET_OPT="--socket=$DB_HOST"
    elif [[ "$DB_HOST" == *":"* ]]; then
        local host_part="${DB_HOST%%:*}"
        local rest="${DB_HOST#*:}"
        if [[ "$rest" =~ ^[0-9]+$ ]]; then
            HOST_OPT="--host=$host_part"; PORT_OPT="--port=$rest"
        elif [[ "$rest" == /* ]]; then
            SOCKET_OPT="--socket=$rest"
        else
            HOST_OPT="--host=$DB_HOST"
        fi
    else
        HOST_OPT="--host=$DB_HOST"
    fi

    local OUT_SQL="../stg-db-export.sql"
    local ERR_LOG="../stg-db-export.err"
    : > "$ERR_LOG"

    # Feature detection
    local GTID_ARG=""
    mysqldump --help 2>/dev/null | grep -q -- "--set-gtid-purged" && GTID_ARG="--set-gtid-purged=OFF"
    local COLSTAT_ARG=""
    mysqldump --help 2>/dev/null | grep -q -- "--column-statistics" && COLSTAT_ARG="--column-statistics=0"

    # First try (full)
    local BASE_ARGS=(
        --user="$DB_USER"
        --default-character-set="${DB_CHARSET:-utf8mb4}"
        --single-transaction
        --quick
        --hex-blob
        --skip-lock-tables
        --triggers
        --routines
        --events
        --max-allowed-packet=512M
        --net-buffer-length=1048576
        --add-drop-table
        --skip-comments
        --no-tablespaces
    )
    [[ -n "$HOST_OPT" ]]   && BASE_ARGS+=("$HOST_OPT")
    [[ -n "$PORT_OPT" ]]   && BASE_ARGS+=("$PORT_OPT")
    [[ -n "$SOCKET_OPT" ]] && BASE_ARGS+=("$SOCKET_OPT")
    [[ -n "$GTID_ARG" ]]   && BASE_ARGS+=("$GTID_ARG")
    [[ -n "$COLSTAT_ARG" ]]&& BASE_ARGS+=("$COLSTAT_ARG")

    log "mysqldump attempt 1 (routines/events/triggers)..."
    set +e
    MYSQL_PWD="$DB_PASSWORD" mysqldump "${BASE_ARGS[@]}" "$DB_NAME" > "$OUT_SQL" 2>>"$ERR_LOG" &
    local dump_pid=$!
    while kill -0 $dump_pid 2>/dev/null; do
        if [[ -f "$OUT_SQL" ]]; then
            local sz=$(stat -c%s "$OUT_SQL" 2>/dev/null || echo "0")
            echo -ne "\r${BLUE}[INFO]${NC} Current size: $(numfmt --to=iec $sz)     "
        fi
        sleep 2
    done
    wait $dump_pid
    local exit_status=$?
    set -e
    echo

    if [[ $exit_status -ne 0 || ! -s "$OUT_SQL" ]]; then
        warning "Attempt 1 failed (see $ERR_LOG). Retrying without routines/events…"
        rm -f "$OUT_SQL"

        local SAFE_ARGS=(
            --user="$DB_USER"
            --default-character-set="${DB_CHARSET:-utf8mb4}"
            --single-transaction
            --quick
            --hex-blob
            --skip-lock-tables
            --triggers
            --max-allowed-packet=512M
            --net-buffer-length=1048576
            --add-drop-table
            --skip-comments
            --no-tablespaces
        )
        [[ -n "$HOST_OPT" ]]   && SAFE_ARGS+=("$HOST_OPT")
        [[ -n "$PORT_OPT" ]]   && SAFE_ARGS+=("$PORT_OPT")
        [[ -n "$SOCKET_OPT" ]] && SAFE_ARGS+=("$SOCKET_OPT")
        [[ -n "$COLSTAT_ARG" ]]&& SAFE_ARGS+=("$COLSTAT_ARG")

        set +e
        MYSQL_PWD="$DB_PASSWORD" mysqldump "${SAFE_ARGS[@]}" "$DB_NAME" > "$OUT_SQL" 2>>"$ERR_LOG" &
        dump_pid=$!
        while kill -0 $dump_pid 2>/dev/null; do
            if [[ -f "$OUT_SQL" ]]; then
                local sz2=$(stat -c%s "$OUT_SQL" 2>/dev/null || echo "0")
                echo -ne "\r${BLUE}[INFO]${NC} Current size: $(numfmt --to=iec $sz2)     "
            fi
            sleep 2
        done
        wait $dump_pid
        exit_status=$?
        set -e
        echo

        if [[ $exit_status -ne 0 || ! -s "$OUT_SQL" ]]; then
            error "Database export failed. See $ERR_LOG"
            exit 1
        fi
    fi

    local final_size=$(stat -c%s "$OUT_SQL" 2>/dev/null || echo "0")
    success "Database exported successfully ($(numfmt --to=iec $final_size))"
}

# --- end CHANGED FUNCTION ---

create_archive() {
    log "Creating website archive..."
    local webroot_size
    webroot_size=$(du -sb "$WEBROOT" 2>/dev/null | cut -f1 || echo "0")
    info "Archiving $(numfmt --to=iec $webroot_size) of data..."
    cd "$WEBROOT/../" || { error "Failed to access parent directory of '$WEBROOT'"; exit 1; }
    tar -czf ROOT.tar.gz \
        --exclude='ROOT/wp-content/ai1wm-backups' \
        --exclude='ROOT/wp-content/backups' \
        --exclude='ROOT/wp-content/backups-dup-pro' \
        --exclude='ROOT/wp-content/updraft' \
        --exclude='ROOT/wp-content/uploads/backup-*' \
        --exclude='ROOT/wp-content/uploads/backwpup-*' \
        --exclude='ROOT/wp-content/cache' \
        --exclude='ROOT/wp-content/uploads/cache' \
        --exclude='ROOT/wp-content/w3tc-cache' \
        --exclude='ROOT/wp-content/wp-rocket-cache' \
        --exclude='ROOT/wp-content/litespeed' \
        --exclude='ROOT/wp-content/debug.log' \
        --exclude='ROOT/wp-content/error_log' \
        --exclude='ROOT/wp-config-backup.php' \
        --exclude='ROOT/error_log' \
        --exclude='ROOT/wp-content/ewww' \
        --exclude='ROOT/wp-content/smush-webp' \
        --exclude='ROOT/wp-content/uploads/wp-file-manager-pro/fm_backup' \
        ROOT 2>/dev/null &
    local tar_pid=$!
    while kill -0 $tar_pid 2>/dev/null; do
        if [[ -f "ROOT.tar.gz" ]]; then
            local current_size
            current_size=$(stat -c%s "ROOT.tar.gz" 2>/dev/null || echo "0")
            echo -ne "\r${BLUE}[INFO]${NC} Current size: $(numfmt --to=iec $current_size)     "
        fi
        sleep 2
    done
    wait $tar_pid
    local exit_status=$?
    echo
    if [[ $exit_status -ne 0 ]]; then
        error "Failed to create archive"
        exit 1
    fi
    local archive_size
    archive_size=$(stat -c%s "ROOT.tar.gz" 2>/dev/null || echo "0")
    success "Website archive created successfully ($(numfmt --to=iec $archive_size))"
}

upload_to_s3() {
    log "Uploading backup files to S3..."
    cd "$WEBROOT/../" || { error "Failed to access backup directory"; exit 1; }
    local db_size
    db_size=$(stat -c%s "stg-db-export.sql" 2>/dev/null || echo "0")
    local archive_size
    archive_size=$(stat -c%s "ROOT.tar.gz" 2>/dev/null || echo "0")
    local total_size=$((db_size + archive_size))
    info "Upload size: $(numfmt --to=iec $total_size)"
    info "Destination: s3://$S3_BUCKET/$SITE_URL/"
    echo
    log "Uploading database export..."
    if ! rclone copy stg-db-export.sql "myaws:$S3_BUCKET/$SITE_URL/" --progress --s3-no-check-bucket; then
        error "Failed to upload database export"
        exit 1
    fi
    success "Database uploaded"
    echo
    log "Uploading website archive..."
    if ! rclone copy ROOT.tar.gz "myaws:$S3_BUCKET/$SITE_URL/" --progress --s3-no-check-bucket; then
        error "Failed to upload website archive"
        exit 1
    fi
    success "Archive uploaded"
    TEMP_FILES="ROOT.tar.gz stg-db-export.sql"
}

verify_backup() {
    log "Verifying backup in S3..."
    local s3_files
    s3_files=$(rclone ls "myaws:$S3_BUCKET/$SITE_URL" 2>/dev/null || true)
    if [[ -z "$s3_files" ]]; then
        error "Failed to verify backup in S3 - no files found"
        exit 1
    fi
    if ! echo "$s3_files" | grep -q "ROOT.tar.gz"; then
        error "Website archive not found in S3"
        exit 1
    fi
    if ! echo "$s3_files" | grep -q "stg-db-export.sql"; then
        error "Database export not found in S3"
        exit 1
    fi
    echo
    info "Backup contents:"
    echo "$s3_files" | while read -r size file; do
        echo "  [OK] $file ($(numfmt --to=iec $size))"
    done
    echo
    success "Backup verification completed successfully"
}

display_summary() {
    echo
    echo "==============================================================="
    info "              *** BACKUP COMPLETED SUCCESSFULLY ***"
    echo "==============================================================="
    echo
    echo ">> Backup Details:"
    echo "   - WordPress site: $SITE_URL"
    echo "   - S3 Location: s3://$S3_BUCKET/$SITE_URL/"
    echo "   - Region: $(get_region_name $AWS_REGION) ($AWS_REGION)"
    echo
    echo ">> Files Uploaded:"
    echo "   - ROOT.tar.gz (Website files)"
    echo "   - stg-db-export.sql (Database - $DB_CHARSET charset)"
    echo
    echo "==============================================================="
    echo
}

main() {
    echo
    echo "==============================================================="
    info "         WordPress S3 Backup Script v2.1 (mysqldump)"
    echo "==============================================================="
    echo
    
    collect_configuration
    echo
    
    check_prerequisites
    check_disk_space
    install_rclone
    setup_rclone
    export_database
    create_archive
    upload_to_s3
    verify_backup
    display_summary
}

main
