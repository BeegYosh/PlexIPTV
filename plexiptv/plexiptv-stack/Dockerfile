FROM python:3.12-slim

LABEL maintainer="PlexIPTV"
LABEL description="Xtream Codes IPTV to Plex Live TV via HDHomeRun emulation"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the plexiptv package
COPY plexiptv/ /app/plexiptv/

RUN mkdir -p /data

ENV PLEXIPTV_CONFIG=/data/config.yaml \
    PLEXIPTV_DB=/data/plexiptv.db

EXPOSE 5004

CMD ["python", "-m", "plexiptv"]
