#!/bin/bash

# Fix misconfigured apt repositories for GitHub CLI and Docker
# This script fixes the Ubuntu Noble 24.04 repository configuration issues

set -e

echo "[INFO] Fixing apt repository configurations..."
echo

# Remove the duplicate/incorrect GitHub CLI repository file
if [ -f "/etc/apt/sources.list.d/archive_uri-https_cli_github_com_packages-noble.list" ]; then
    echo "[INFO] Removing incorrect GitHub CLI repository file..."
    sudo rm /etc/apt/sources.list.d/archive_uri-https_cli_github_com_packages-noble.list
    echo "[INFO] Removed: archive_uri-https_cli_github_com_packages-noble.list"
else
    echo "[INFO] Incorrect GitHub CLI repository file not found (already removed)"
fi

echo

# Fix Docker repository configuration (change debian to ubuntu)
if [ -f "/etc/apt/sources.list.d/docker.list" ]; then
    echo "[INFO] Fixing Docker repository configuration..."
    echo "   Current: $(cat /etc/apt/sources.list.d/docker.list)"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    echo "   Updated: $(cat /etc/apt/sources.list.d/docker.list)"
    echo "[INFO] Fixed Docker repository"
else
    echo "[INFO] Docker repository file not found"
fi

echo

# Update package lists
echo "[INFO] Updating package lists..."
if sudo nala update; then
    echo "[INFO] Package lists updated successfully!"
    echo
    echo "Repository configuration fixed!"
    echo
    echo "You can now run your scripts without repository errors."
else
    echo "[ERROR] Failed to update package lists. Please check for other issues."
    exit 1
fi
