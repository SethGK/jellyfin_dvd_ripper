#!/bin/bash

# TV Show DVD Ripping Script for Jellyfin - Multi-Disc Version
# Usage: ./rip_tv.sh "Series Name (Year)" "Season Number" [Starting Episode Number] [Number of Episodes]

set -e

# Configuration
CONTAINER_ID=106
TEMP_DIR="/tmp/tv-rip"
JELLYFIN_PATH="/mnt/storage/media/jellyfin/tv_shows"
DVD_DEVICE="/dev/sr0"
MOUNT_POINT="/mnt/cdrom"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    log_info "Cleaning up..."
    umount "$MOUNT_POINT" 2>/dev/null || true
    rm -rf "$TEMP_DIR"
    log_success "Cleanup complete"
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Check arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    log_error "Usage: $0 \"Series Name (Year)\" \"Season Number\" [Starting Episode Number] [Number of Episodes]"
    log_error "Examples:"
    log_error "  $0 \"The Sopranos (1999)\" \"01\"           # Interactive mode from episode 1"
    log_error "  $0 \"The Sopranos (1999)\" \"01\" 5        # Interactive mode from episode 5"
    log_error "  $0 \"The Sopranos (1999)\" \"01\" 1 3      # Auto-rip episodes 1-3 (batch mode)"
    log_error "  $0 \"Friends (1994)\" \"02\" 10 4          # Auto-rip episodes 10-13 (batch mode)"
    exit 1
fi

SERIES_NAME="$1"
SEASON_NUM="$2"
START_EPISODE=${3:-1}  # Default to episode 1 if not specified
NUM_EPISODES="$4"      # If specified, run in batch mode
SAFE_SERIES=$(echo "$SERIES_NAME" | sed 's/[^a-zA-Z0-9 ()-]/_/g')

# Format season number (pad with zero if needed)
SEASON_FORMATTED=$(printf "%02d" "$SEASON_NUM" 2>/dev/null || echo "$SEASON_NUM")

# Determine mode
if [ -n "$NUM_EPISODES" ]; then
    BATCH_MODE=true
    END_EPISODE=$((START_EPISODE + NUM_EPISODES - 1))
    log_info "Running in BATCH MODE"
    log_info "Starting TV rip for: $SERIES_NAME Season $SEASON_FORMATTED"
    log_info "Episodes: $START_EPISODE through $END_EPISODE ($NUM_EPISODES episodes)"
else
    BATCH_MODE=false
    log_info "Running in INTERACTIVE MODE"
    log_info "Starting TV rip for: $SERIES_NAME Season $SEASON_FORMATTED"
    log_info "Starting episode number: $START_EPISODE"
fi

# Ask about disc info for better organization (only in interactive mode)
if [ "$BATCH_MODE" = false ]; then
    echo ""
    read -p "What disc is this? (e.g., 'Disc 1', 'Disc 2', or leave blank): " DISC_INFO
    if [ -n "$DISC_INFO" ]; then
        log_info "Processing $DISC_INFO"
    fi
fi

# Step 1: Create directories
log_info "Creating directories..."
mkdir -p "$TEMP_DIR"
mkdir -p "$MOUNT_POINT"

# Step 2: Mount DVD
log_info "Mounting DVD..."
if ! mount "$DVD_DEVICE" "$MOUNT_POINT"; then
    log_error "Failed to mount DVD. Make sure DVD is inserted."
    exit 1
fi
log_success "DVD mounted successfully"

# Step 3: Scan DVD
log_info "Scanning DVD for episodes..."
if ! HandBrakeCLI --input "$DVD_DEVICE" --title 0 --preview 1 --scan > "$TEMP_DIR/scan.log" 2>&1; then
    log_error "Failed to scan DVD. Check scan.log for details."
    cat "$TEMP_DIR/scan.log"
    exit 1
fi

# Parse titles and durations
log_info "Analyzing titles..."

echo ""
echo "==================== AVAILABLE TITLES ===================="
if [ -n "$DISC_INFO" ]; then
    echo "Processing: $DISC_INFO"
fi

# More robust duration parsing - look for duration anywhere in the next few lines
awk '
/^\+ title/ {
    title_num = $3
    gsub(/:/, "", title_num)
    duration = "Unknown"
    
    # Read the next several lines to find duration
    for (i = 1; i <= 10; i++) {
        if ((getline line) > 0) {
            if (match(line, /duration: ([0-9]+):([0-9]+):([0-9]+)/)) {
                duration = substr(line, RSTART + 10, RLENGTH - 10)
                break
            }
        } else {
            break
        }
    }
    
    printf "Title %-2s: %s\n", title_num, duration
}' "$TEMP_DIR/scan.log"

echo "=========================================================="

# Debug: Show raw scan output if durations are still unknown
if ! awk '/duration: [0-9]+:[0-9]+:[0-9]+/ {found=1} END {exit !found}' "$TEMP_DIR/scan.log"; then
    log_warning "Duration parsing may have issues. Showing raw scan excerpt:"
    echo "--- First 50 lines of scan log ---"
    head -50 "$TEMP_DIR/scan.log"
    echo "--- End excerpt ---"
fi

# Step 4: Create container directory structure
log_info "Creating directory structure in container..."
pct exec "$CONTAINER_ID" -- mkdir -p "$JELLYFIN_PATH/$SERIES_NAME/Season $SEASON_FORMATTED"

EPISODE_NUM=$START_EPISODE

# Step 5: Choose mode
if [ "$BATCH_MODE" = true ]; then
    # Batch Mode: Auto-detect episode titles and rip specified number
    log_info "Auto-detecting episode titles (20+ minutes duration)..."
    
    # Get titles with duration >= 20 minutes, sorted by title number
    EPISODE_TITLES=$(awk '
    /^\+ title/ {
        title_num = $3
        gsub(/:/, "", title_num)
        
        # Read the next several lines to find duration
        for (i = 1; i <= 10; i++) {
            if ((getline line) > 0) {
                if (match(line, /duration: [0-9]+:[0-9]+:[0-9]+/)) {
                    duration_str = substr(line, RSTART + 10)
                    split(duration_str, time_parts, ":")
                    hours = time_parts[1]
                    minutes = time_parts[2]
                    total_minutes = hours * 60 + minutes
                    
                    if (total_minutes >= 20) {
                        print title_num
                    }
                    break
                }
            } else {
                break
            }
        }
    }' "$TEMP_DIR/scan.log" | sort -n)

    if [ -z "$EPISODE_TITLES" ]; then
        log_error "No titles found with 20+ minute duration. Check the scan results above."
        exit 1
    fi

    # Convert to array
    TITLE_ARRAY=($EPISODE_TITLES)
    FOUND_TITLES=${#TITLE_ARRAY[@]}

    log_info "Found $FOUND_TITLES episode titles: ${TITLE_ARRAY[*]}"

    # Check if we have enough titles for the requested episodes
    if [ $NUM_EPISODES -gt $FOUND_TITLES ]; then
        log_error "Requested $NUM_EPISODES episodes but only found $FOUND_TITLES suitable titles"
        log_info "Available titles: ${TITLE_ARRAY[*]}"
        exit 1
    fi

    # Rip the episodes
    for i in $(seq 0 $((NUM_EPISODES - 1))); do
        if [ $i -ge $FOUND_TITLES ]; then
            log_warning "No more titles available for episode $EPISODE_NUM"
            break
        fi
        
        TITLE_NUM=${TITLE_ARRAY[$i]}
        EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
        OUTPUT_FILE="$TEMP_DIR/${SAFE_SERIES}_S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
        
        log_info "Ripping Episode $EPISODE_FORMATTED from Title $TITLE_NUM..."
        
        if HandBrakeCLI \
            --input "$DVD_DEVICE" \
            --title "$TITLE_NUM" \
            --output "$OUTPUT_FILE" \
            --preset "Fast 1080p30" \
            --subtitle scan,1,2 \
            --subtitle-burned none; then
            
            # Transfer to container
            CONTAINER_FILE="$JELLYFIN_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
            if pct push "$CONTAINER_ID" "$OUTPUT_FILE" "$CONTAINER_FILE"; then
                # Remove the local file after successful transfer
                rm -f "$OUTPUT_FILE"
                log_success "Episode $EPISODE_FORMATTED completed and transferred"
            else
                log_error "Failed to transfer Episode $EPISODE_FORMATTED to container"
            fi
            
            EPISODE_NUM=$((EPISODE_NUM + 1))
        else
            log_error "Failed to rip Episode $EPISODE_FORMATTED from Title $TITLE_NUM"
        fi
    done

else
    # Interactive Mode: Original menu system
    echo ""
    echo "📺 Episode Ripping Mode"
    echo "Choose how to proceed:"
    echo "1) Auto-rip episodes (titles 20+ minutes each as separate episodes)"
    echo "2) Manual selection (choose specific titles)"
    echo "3) Rip all titles as separate episodes"
    echo ""
    read -p "Enter choice (1-3): " -n 1 -r CHOICE
    echo ""

    case $CHOICE in
        1)
            log_info "Auto-ripping episodes (20+ minutes)..."
            
            # Get titles with duration >= 20 minutes
            awk '
            /^\+ title/ {
                title_num = $3
                gsub(/:/, "", title_num)
                
                # Read the next several lines to find duration
                for (i = 1; i <= 10; i++) {
                    if ((getline line) > 0) {
                        if (match(line, /duration: ([0-9]+):([0-9]+):([0-9]+)/, dur_match)) {
                            duration_str = dur_match[0]
                            gsub(/duration: /, "", duration_str)
                            split(duration_str, time_parts, ":")
                            hours = time_parts[1]
                            minutes = time_parts[2]
                            total_minutes = hours * 60 + minutes
                            
                            if (total_minutes >= 20) {
                                print title_num
                            }
                            break
                        }
                    } else {
                        break
                    }
                }
            }' "$TEMP_DIR/scan.log" | sort -n | while read title_num; do
                
                EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
                OUTPUT_FILE="$TEMP_DIR/${SAFE_SERIES}_S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                
                log_info "Ripping Episode $EPISODE_FORMATTED (Title $title_num)..."
                if [ -n "$DISC_INFO" ]; then
                    log_info "From $DISC_INFO"
                fi
                
                if HandBrakeCLI \
                    --input "$DVD_DEVICE" \
                    --title "$title_num" \
                    --output "$OUTPUT_FILE" \
                    --preset "Fast 1080p30" \
                    --subtitle scan,1,2 \
                    --subtitle-burned none; then
                    
                    # Transfer to container
                    CONTAINER_FILE="$JELLYFIN_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                    if pct push "$CONTAINER_ID" "$OUTPUT_FILE" "$CONTAINER_FILE"; then
                        # Remove the local file after successful transfer
                        rm -f "$OUTPUT_FILE"
                        log_success "Episode $EPISODE_FORMATTED completed and transferred"
                    else
                        log_error "Failed to transfer Episode $EPISODE_FORMATTED to container"
                    fi
                    
                    EPISODE_NUM=$((EPISODE_NUM + 1))
                else
                    log_warning "Failed to rip Episode $EPISODE_FORMATTED"
                fi
            done
            ;;
            
        2)
            log_info "Manual selection mode"
            
            while true; do
                echo ""
                read -p "Enter title number to rip (or 'done' to finish): " title_input
                
                if [ "$title_input" = "done" ] || [ "$title_input" = "d" ]; then
                    break
                fi
                
                if [[ "$title_input" =~ ^[0-9]+$ ]]; then
                    EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
                    
                    # Ask for custom episode name
                    read -p "Episode name (default: E${EPISODE_FORMATTED}): " custom_name
                    if [ -n "$custom_name" ]; then
                        EPISODE_NAME="${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED} ${custom_name}.mkv"
                    else
                        EPISODE_NAME="${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                    fi
                    
                    OUTPUT_FILE="$TEMP_DIR/episode_${EPISODE_NUM}.mkv"
                    
                    log_info "Ripping Title $title_input as Episode $EPISODE_FORMATTED..."
                    if [ -n "$DISC_INFO" ]; then
                        log_info "From $DISC_INFO"
                    fi
                    
                    if HandBrakeCLI \
                        --input "$DVD_DEVICE" \
                        --title "$title_input" \
                        --output "$OUTPUT_FILE" \
                        --preset "Fast 1080p30" \
                        --subtitle scan,1,2 \
                        --subtitle-burned none; then
                        
                        # Transfer to container
                        CONTAINER_FILE="$JELLYFIN_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/$EPISODE_NAME"
                        if pct push "$CONTAINER_ID" "$OUTPUT_FILE" "$CONTAINER_FILE"; then
                            # Remove the local file after successful transfer
                            rm -f "$OUTPUT_FILE"
                            log_success "Episode $EPISODE_FORMATTED completed and transferred: $EPISODE_NAME"
                        else
                            log_error "Failed to transfer Episode $EPISODE_FORMATTED to container"
                        fi
                        
                        EPISODE_NUM=$((EPISODE_NUM + 1))
                    else
                        log_warning "Failed to rip Episode $EPISODE_FORMATTED"
                    fi
                else
                    log_warning "Invalid title number: $title_input"
                fi
            done
            ;;
            
        3)
            log_info "Ripping all titles as episodes..."
            
            # Get all title numbers
            awk '/^\+ title/ {
                title_num = $3
                gsub(/:/, "", title_num)
                print title_num
            }' "$TEMP_DIR/scan.log" | sort -n | while read title_num; do
                
                EPISODE_FORMATTED=$(printf "%02d" "$EPISODE_NUM")
                OUTPUT_FILE="$TEMP_DIR/${SAFE_SERIES}_S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                
                log_info "Ripping Episode $EPISODE_FORMATTED (Title $title_num)..."
                if [ -n "$DISC_INFO" ]; then
                    log_info "From $DISC_INFO"
                fi
                
                if HandBrakeCLI \
                    --input "$DVD_DEVICE" \
                    --title "$title_num" \
                    --output "$OUTPUT_FILE" \
                    --preset "Fast 1080p30" \
                    --subtitle scan,1,2 \
                    --subtitle-burned none; then
                    
                    # Transfer to container
                    CONTAINER_FILE="$JELLYFIN_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/${SAFE_SERIES} S${SEASON_FORMATTED}E${EPISODE_FORMATTED}.mkv"
                    if pct push "$CONTAINER_ID" "$OUTPUT_FILE" "$CONTAINER_FILE"; then
                        # Remove the local file after successful transfer
                        rm -f "$OUTPUT_FILE"
                        log_success "Episode $EPISODE_FORMATTED completed and transferred"
                    else
                        log_error "Failed to transfer Episode $EPISODE_FORMATTED to container"
                    fi
                    
                    EPISODE_NUM=$((EPISODE_NUM + 1))
                else
                    log_warning "Failed to rip Episode $EPISODE_FORMATTED"
                fi
            done
            ;;
            
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
fi

# Show what episode number to start with for next disc
NEXT_EPISODE=$EPISODE_NUM
log_info "For the next disc, start with episode number: $NEXT_EPISODE"
if [ "$BATCH_MODE" = true ]; then
    log_info "Next batch command: ./rip_tv.sh \"$SERIES_NAME\" \"$SEASON_NUM\" $NEXT_EPISODE [number_of_episodes_on_next_disc]"
else
    log_info "Next interactive command: ./rip_tv.sh \"$SERIES_NAME\" \"$SEASON_NUM\" $NEXT_EPISODE"
fi

# Handle specials
if [ "$SEASON_NUM" = "00" ] || [ "$SEASON_NUM" = "0" ]; then
    echo ""
    read -p "Add custom names for specials? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "You can rename files in the container if needed"
        pct exec "$CONTAINER_ID" -- ls -la "$JELLYFIN_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/"
    fi
fi

# Set permissions
log_info "Setting permissions..."
pct exec "$CONTAINER_ID" -- chown -R root:jellymedia "$JELLYFIN_PATH/$SERIES_NAME/"
pct exec "$CONTAINER_ID" -- chmod -R 755 "$JELLYFIN_PATH/$SERIES_NAME/"

# Show final results
log_info "Final directory structure:"
pct exec "$CONTAINER_ID" -- find "$JELLYFIN_PATH/$SERIES_NAME/" -type f -name "*.mkv" | sort

# Eject DVD
log_info "Ejecting DVD..."
eject "$DVD_DEVICE"

log_success "TV Show rip complete!"
if [ -n "$DISC_INFO" ]; then
    log_info "$DISC_INFO processed"
fi
log_info "Series: $SERIES_NAME"
log_info "Season: $SEASON_FORMATTED"
log_info "Episodes: $START_EPISODE - $((EPISODE_NUM - 1))"

echo ""
echo "====== SUMMARY ======"
echo "Series: $SERIES_NAME"
echo "Season: $SEASON_FORMATTED"
if [ -n "$DISC_INFO" ]; then
    echo "Disc: $DISC_INFO"
fi
echo "Episodes processed: $START_EPISODE - $((EPISODE_NUM - 1))"
echo "Location: $JELLYFIN_PATH/$SERIES_NAME/Season $SEASON_FORMATTED/"
echo "Next disc should start with episode: $NEXT_EPISODE"
if [ "$BATCH_MODE" = true ]; then
    echo "Mode: Batch (auto-ripped $NUM_EPISODES episodes)"
else
    echo "Mode: Interactive"
fi
echo "===================="