#!/bin/sh
# Copy default config if none exists in the data volume
if [ ! -f /app/data/config.yaml ]; then
    mkdir -p /app/data
    cp /app/config.default.yaml /app/data/config.yaml
    echo "Created default config at /app/data/config.yaml"
fi

# Wipe old database on every start so channels re-sync
# with the latest CATEGORY_FILTER / CHANNEL_FILTER / CATEGORY_EXCLUDE
if [ -f /app/data/plexiptv.db ]; then
    rm -f /app/data/plexiptv.db
    echo "Cleared channel cache — will re-sync from provider"
fi

exec "$@"
