FROM python:3.12-slim

LABEL maintainer="Mauro <mauro@bigmodeconsulting.com>"
LABEL description="PlexIPTV — Xtream Codes IPTV to Plex Live TV via HDHomeRun emulation"

# Prevent Python from buffering stdout/stderr (important for Docker logs)
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install dependencies first (layer caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . /app/plexiptv/

# Create data directory for config and database persistence
RUN mkdir -p /data

# Default config location
ENV PLEXIPTV_CONFIG=/data/config.yaml \
    PLEXIPTV_DB=/data/plexiptv.db

# Expose the default port
EXPOSE 5004

# Use network host mode is recommended in docker-compose for SSDP
# but the app still works without it — Plex just won't auto-discover

CMD ["python", "-m", "plexiptv"]
