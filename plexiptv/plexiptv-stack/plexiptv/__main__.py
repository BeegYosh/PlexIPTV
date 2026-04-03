"""Entry point for `python -m plexiptv` or the `plexiptv` console script."""

import uvicorn

from plexiptv.app import create_app
from plexiptv.config import load_config


def main() -> None:
    settings = load_config()
    app = create_app()
    uvicorn.run(
        app,
        host=settings.server.host,
        port=settings.server.port,
        log_level="info",
        access_log=True,
    )


if __name__ == "__main__":
    main()
