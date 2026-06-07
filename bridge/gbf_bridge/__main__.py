"""Entry point: `uv run gbf-bridge` or `python -m gbf_bridge`."""

from __future__ import annotations

import argparse
import asyncio
import logging

from .server import Bridge

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8770


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="gbf-bridge",
        description="Bridge BLE cycling sensors to a localhost WebSocket.",
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help="bind host")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="bind port")
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    bridge = Bridge(args.host, args.port)
    try:
        asyncio.run(bridge.run())
    except KeyboardInterrupt:
        print()  # tidy the ^C
        logging.getLogger("gbf_bridge").info("shutting down")


if __name__ == "__main__":
    main()
