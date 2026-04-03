FROM python:3.12-slim

LABEL description="Xtream Codes IPTV to Plex Live TV via HDHomeRun emulation"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY pyproject.toml .
COPY plexiptv/ plexiptv/
COPY config.yaml /app/config.default.yaml
COPY entrypoint.sh /app/entrypoint.sh

RUN pip install --no-cache-dir . && chmod +x /app/entrypoint.sh

RUN mkdir -p /app/data

ENV PLEXIPTV_CONFIG=/app/data/config.yaml \
    PLEXIPTV_DB=/app/data/plexiptv.db

EXPOSE 5004

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["plexiptv"]
