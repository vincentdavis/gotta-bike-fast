#!/usr/bin/env python3
"""Serve the exported Godot web build locally for testing.

    python tools/web/serve.py            # serves build/web on :8060
    python tools/web/serve.py --port 9000 --dir build/web

Sets the correct wasm/js MIME types and disables caching so a re-export shows
up on a plain refresh. The build is exported with thread support OFF, so no
cross-origin-isolation (COOP/COEP) headers are needed and the game's API calls
aren't blocked — keep it that way unless you switch the preset to threads.

Open the printed URL in Chrome, Edge, or Firefox.
"""
import argparse
import functools
import http.server
import socketserver

EXTRA_MIME = {
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".wasm": "application/wasm",
    ".pck": "application/octet-stream",
    ".data": "application/octet-stream",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, **EXTRA_MIME}

    def end_headers(self):
        # No-store so re-exports are picked up without a hard refresh.
        self.send_header("Cache-Control", "no-store, max-age=0")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass  # quiet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="build/web", help="exported web build directory")
    ap.add_argument("--port", type=int, default=8060)
    args = ap.parse_args()

    handler = functools.partial(Handler, directory=args.dir)
    with socketserver.TCPServer(("127.0.0.1", args.port), handler) as httpd:
        url = f"http://127.0.0.1:{args.port}/"
        print(f"Serving {args.dir} at {url}  (Ctrl-C to stop)")
        print("Open it in Chrome / Edge / Firefox.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
