#!/bin/bash

# TV Show DVD Ripping Script for Jellyfin - Multi-Disc Version
# Usage: ./rip_tv.sh "Series Name (Year)" "Season Number" [Starting Episode Number] [Number of Episodes]

set -e

# Configuration
CONTAINER_ID=106
TEMP_DIR="/tmp/tv-rip"
JELLYFIN_PATH="/mnt/storage/media/jellyfin/tv_shows"
HDD_PATH="/mnt/jellyfin/tv_shows"
DVD_DEVICE="/dev/sr0"
MOUNT_POINT="/mnt/cdrom"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    log_info "Cleaning up..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    rm -rf "$TEMP_DIR"
    log_success "Cleanup complete"
}

trap cleanup EXIT

# Check args
if [ -z "$1" ] || [ -z "$2" ]; then
    log_error "Usage: $0 \"Series Name (Year)\" \"Season Number\" [Starting Episode Number] [Number of Episodes]"
    exit 1
fi

SERIES_NAME="$1"
SEASON_NUM="$2"
START_EPISODE=${3:-1}
NUM_EPISODES="$4"
SAFE_SERIES=$(echo "$SERIES_NAME" | sed 's/[^a-zA-Z0-9 ()-]/_/g')
SEASON_FORMATTED=$(printf "%02d" "$SEASON_NUM" 2>/dev/null || echo "$SEASON_NUM")

# Ask where to save
echo ""
echo "Where do you want to save the ripped episodes?"
echo "1) Save to Jellyfin container ($JELLYFIN_PATH)"
echo "2) Save to 500GB HDD ($HDD_PATH)"
read -p "Enter choice (1 or 2): " STORAGE_CHOICE
case $STORAGE_CHOICE in
    1) OUTPUT_PATH="$JELLYFIN_PATH"; SAVE_TO_CONTAINER=true ;;
    2) OUTPUT_PATH="$HDD_PATH"; SAVE_TO_CONTAINER=false ;;
    *) log_warning "Invalid choice. Defaulting to Jellyfin container."; OUTPUT_PATH="$JELLYFIN_PATH"; SAVE_TO_CONTAINER=true ;;
esac

# Mode detection
if [ -n "$NUM_EPISODES" ]; then
    BATCH_MODE=true
    END_EPISODE=$((START_EPISODE + NUM_EPISODES - 1))
else
    BATCH_MODE=false
fi

# Disc info (interactive only)
if [ "$BATCH_MODE" = false ]; then
    read -p "What disc is this? (optional): " DISC_INFO
fi

# Create dirs
mkdir -p "$TEMP_DIR" "$MOUNT_POINT"

# Mount DVD
log_info "Mounting DVD..."
if ! mount "$DVD_DEVICE" "$MOUNT_POINT"; then
    log_error "Failed to mount DVD"
    exit 1
fi
log_success "DVD mounted"

# Scan DVD
log_info "Scanning DVD..."
if ! HandBrakeCLI --input "$DVD_DEVICE" --title 0 --preview 1 --scan > "$TEMP_DIR/scan.log" 2>&1; then
    log_error "Scan failed"
    exit 1
fi

# Show available titles
awk '
/^\+ title/ {
    title_num = $3; gsub(/:/, "", title_num)
    for (i=1;i<=10;i++) {
        if ((getline line) > 0) {
            if (match(line, /duration: ([0-9]+):([0-9]+):([0-9]+)/)) {
                dur = substr(line, RSTART+10, RLENGTH-10)
                printf "Title %-2s: %s\n", title_num, dur
                break
            }
        }
    }
}' "$TEMP_DIR/scan.log"

# Ensure target dir exists
if [ "$SAVE_TO_CONTAINER" = true ]; then
    pct exec "$CONTAINER_ID" -- mkdir -p "$OUTPUT_PATH/$SERIES_NAME/Season $SEASON_FORMATTED"
else
    mkdir -p "$OUTPUT_PATH/$SERIES_NAME/Season $SEASON_FORMATTED"
fi

EPISODE_NUM=$START_EPISODE

transfer_file() {
    local src="$1"
    local dest_name="$2"
    if [ "$SAVE_TO_CONTAINER" = true ]; then
        pct push "$CONTAINER_ID" "$src" "$OUTPUT_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/$dest_name" && rm -f "$src"
    else
        mv "$src" "$OUTPUT_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/$dest_name"
    fi
}

# Batch mode
if [ "$BATCH_MODE" = true ]; then
    EPISODE_TITLES=$(awk '
    /^\+ title/ {
        t=$3; gsub(/:/, "", t)
        for (i=1;i<=10;i++) {
            if ((getline line) > 0) {
                if (match(line, /duration: ([0-9]+):([0-9]+):([0-9]+)/, m)) {
                    min=m[1]*60 + m[2]
                    if (min >= 20) print t
                    break
                }
            }
        }
    }' "$TEMP_DIR/scan.log" | sort -n)

    TITLE_ARRAY=($EPISODE_TITLES)
    for i in $(seq 0 $((NUM_EPISODES-1))); do
        TITLE_NUM=${TITLE_ARRAY[$i]}
        EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
        OUTPUT_FILE="$TEMP_DIR/${SAFE_SERIES}_S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
        if HandBrakeCLI --input "$DVD_DEVICE" --title "$TITLE_NUM" --output "$OUTPUT_FILE" --preset "Fast 1080p30" --subtitle scan,1,2 --subtitle-burned none; then
            transfer_file "$OUTPUT_FILE" "${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
            EPISODE_NUM=$((EPISODE_NUM+1))
        fi
    done
else
    echo "1) Auto-rip (20+ min)"
    echo "2) Manual"
    echo "3) All titles"
    read -p "Choice: " CHOICE
    case $CHOICE in
        1)
            awk '
            /^\+ title/ {
                t=$3; gsub(/:/, "", t)
                for (i=1;i<=10;i++) {
                    if ((getline line) > 0) {
                        if (match(line, /duration: ([0-9]+):([0-9]+):([0-9]+)/, m)) {
                            min=m[1]*60 + m[2]
                            if (min >= 20) print t
                            break
                        }
                    }
                }
            }' "$TEMP_DIR/scan.log" | sort -n | while read title_num; do
                EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
                OUTPUT_FILE="$TEMP_DIR/${SAFE_SERIES}_S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                if HandBrakeCLI --input "$DVD_DEVICE" --title "$title_num" --output "$OUTPUT_FILE" --preset "Fast 1080p30" --subtitle scan,1,2 --subtitle-burned none; then
                    transfer_file "$OUTPUT_FILE" "${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                    EPISODE_NUM=$((EPISODE_NUM+1))
                fi
            done
            ;;
        2)
            while true; do
                read -p "Title number (or 'done'): " t
                [ "$t" = "done" ] && break
                EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
                OUTPUT_FILE="$TEMP_DIR/episode_${EPISODE_NUM}.mkv"
                if HandBrakeCLI --input "$DVD_DEVICE" --title "$t" --output "$OUTPUT_FILE" --preset "Fast 1080p30" --subtitle scan,1,2 --subtitle-burned none; then
                    transfer_file "$OUTPUT_FILE" "${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                    EPISODE_NUM=$((EPISODE_NUM+1))
                fi
            done
            ;;
        3)
            awk '/^\+ title/ {t=$3; gsub(/:/,"",t); print t}' "$TEMP_DIR/scan.log" | sort -n | while read title_num; do
                EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
                OUTPUT_FILE="$TEMP_DIR/${SAFE_SERIES}_S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                if HandBrakeCLI --input "$DVD_DEVICE" --title "$title_num" --output "$OUTPUT_FILE" --preset "Fast 1080p30" --subtitle scan,1,2 --subtitle-burned none; then
                    transfer_file "$OUTPUT_FILE" "${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                    EPISODE_NUM=$((EPISODE_NUM+1))
                fi
            done
            ;;
    esac
fi

# Permissions
if [ "$SAVE_TO_CONTAINER" = true ]; then
    pct exec "$CONTAINER_ID" -- chown -R root:jellymedia "$OUTPUT_PATH/$SERIES_NAME/"
    pct exec "$CONTAINER_ID" -- chmod -R 755 "$OUTPUT_PATH/$SERIES_NAME/"
else
    chown -R root:jellymedia "$OUTPUT_PATH/$SERIES_NAME/"
    chmod -R 755 "$OUTPUT_PATH/$SERIES_NAME/"
fi

# Eject DVD
eject "$DVD_DEVICE"
log_success "TV Show rip complete!"
