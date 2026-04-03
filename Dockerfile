FROM python:3.12-slim

LABEL description="Xtream Codes IPTV to Plex Live TV via HDHomeRun emulation"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install dependencies directly (no pip install of the package itself)
RUN pip install --no-cache-dir \
    "fastapi>=0.110" \
    "uvicorn[standard]>=0.27" \
    "httpx>=0.27" \
    "aiosqlite>=0.20" \
    "pyyaml>=6.0" \
    "pydantic>=2.6"

# Copy application code directly into /app
COPY plexiptv/ /app/plexiptv/
COPY config.yaml /app/config.default.yaml
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

RUN mkdir -p /app/data

ENV PLEXIPTV_CONFIG=/app/data/config.yaml \
    PLEXIPTV_DB=/app/data/plexiptv.db

EXPOSE 5004

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python", "-m", "plexiptv"]
