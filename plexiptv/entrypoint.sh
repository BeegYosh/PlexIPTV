#!/bin/sh
# Copy default config if none exists in the data volume
if [ ! -f /app/data/config.yaml ]; then
    mkdir -p /app/data
    cp /app/config.default.yaml /app/data/config.yaml
    echo "Created default config at /app/data/config.yaml"
fi

exec "$@"
