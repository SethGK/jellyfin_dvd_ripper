#!/bin/bash

# Quick DVD Rip Script - Main movie only, no prompts
# Usage: ./quick_rip.sh "Movie Title (Year)"

CONTAINER_ID=106
TEMP_DIR="/tmp/dvd-rip"
JELLYFIN_PATH="/mnt/storage/media/jellyfin/movies"
MOVIE_TITLE="$1"
SAFE_TITLE=$(echo "$MOVIE_TITLE" | sed 's/[^a-zA-Z0-9 ()-]/_/g')

if [ -z "$1" ]; then
    echo "Usage: $0 \"Movie Title (Year)\""
    exit 1
fi

echo "🎬 Quick ripping: $MOVIE_TITLE"

# Setup
mkdir -p "$TEMP_DIR"
mkdir -p /mnt/cdrom
mount /dev/sr0 /mnt/cdrom

# Create container directory
pct exec "$CONTAINER_ID" -- mkdir -p "$JELLYFIN_PATH/$MOVIE_TITLE"

# Rip main movie (assume title 1)
echo "🎥 Ripping main movie..."
HandBrakeCLI --input /dev/sr0 --title 1 --output "$TEMP_DIR/${SAFE_TITLE}.mkv" --preset "Fast 1080p30"

# Transfer
echo "📦 Transferring to Jellyfin..."
pct push "$CONTAINER_ID" "$TEMP_DIR/${SAFE_TITLE}.mkv" "$JELLYFIN_PATH/$MOVIE_TITLE/${SAFE_TITLE}.mkv"

# Set permissions
pct exec "$CONTAINER_ID" -- chown -R root:jellymedia "$JELLYFIN_PATH/$MOVIE_TITLE/"
pct exec "$CONTAINER_ID" -- chmod -R 755 "$JELLYFIN_PATH/$MOVIE_TITLE/"

# Cleanup
umount /mnt/cdrom
rm -rf "$TEMP_DIR"
eject /dev/sr0

echo "✅ Done! $MOVIE_TITLE is ready in Jellyfin"