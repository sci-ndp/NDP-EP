#!/bin/bash
set -e

echo "🚨 Stopping and removing NDP stack components..."

# List of folders used by the NDP setup
components=(ckan sciDX-kafka dspaces-api pop jhub)

# Gracefully shut down and remove containers/networks
for dir in "${components[@]}"; do
  if [ -d "$dir" ]; then
    echo "📁 Found $dir. Attempting to shut down Docker containers..."
    (cd "$dir" && docker-compose down || docker compose down || true)
    echo "🗑️ Removing $dir folder..."
    rm -rf "$dir"
  else
    echo "❌ Directory $dir not found. Skipping..."
  fi
done

# Remove generated info file
if [ -f "user_info.txt" ]; then
  echo "🗑️ Removing user_info.txt..."
  rm -f user_info.txt
fi

echo "✅ All services stopped and cleaned up successfully."
