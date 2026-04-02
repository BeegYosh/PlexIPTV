FROM python:3.12-slim

WORKDIR /app

COPY pyproject.toml .
COPY plexiptv/ plexiptv/
COPY config.yaml /app/config.default.yaml
COPY entrypoint.sh /app/entrypoint.sh

RUN pip install --no-cache-dir . && chmod +x /app/entrypoint.sh

VOLUME /app/data
ENV PLEXIPTV_CONFIG=/app/data/config.yaml
ENV PLEXIPTV_DB=/app/data/plexiptv.db

EXPOSE 5004

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["plexiptv"]
