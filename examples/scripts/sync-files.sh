#!/bin/bash
# Sync files to remote server or cloud storage
# Triggered by: sync-trigger topic (silent)

# Command output is not persisted; avoid shared /tmp logs and notification text.
LOG_FILE="/dev/null"

echo "$(date): Sync triggered" >> "$LOG_FILE"

# Example: Sync to remote server via rsync
# rsync -avz --delete ~/Documents/ user@server:/backup/Documents/ >> "$LOG_FILE" 2>&1

# Example: Sync to S3
# aws s3 sync ~/Documents s3://mybucket/Documents --delete >> "$LOG_FILE" 2>&1

# Example: Sync via rclone
# rclone sync ~/Documents gdrive:Backup/Documents >> "$LOG_FILE" 2>&1

echo "$(date): Sync complete" >> "$LOG_FILE"
