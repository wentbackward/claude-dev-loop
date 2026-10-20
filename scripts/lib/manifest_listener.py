"""One-shot local listener for the GitHub App manifest flow.

GET /          a page that posts the app manifest to GitHub's "new app" form (one "Create" click there)
GET /callback  GitHub redirects here with ?code=...&state=...; the code is written to OUTPUT and the
               listener exits.
Usage: python3 -I manifest_listener.py PORT MANIFEST_FILE FORM_URL STATE OUTPUT_FILE [TIMEOUT_SECONDS]
"""

import html
import http.server
import sys
import threading
import urllib.parse


def make_handler(
    manifest: str, form_url: str, state: str, output: str, done: threading.Event
) -> type:
    """A request handler bound to one manifest and one expected state."""

    class Handler(http.server.BaseHTTPRequestHandler):
        """Serves the form page and receives the callback."""

        def log_message(self, format: str, *args: object) -> None:
            """Keep the terminal quiet."""

        def reply(self, status: int, body: str) -> None:
            """Send a small HTML page."""
            data = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            """Route / and /callback."""
            url = urllib.parse.urlparse(self.path)
            if url.path == "/":
                action = f"{form_url}?state={urllib.parse.quote(state)}"
                self.reply(
                    200,
                    (
                        "<!doctype html><meta charset='utf-8'><title>dev-loop app</title>"
                        f"<form id='f' method='post' action='{html.escape(action, quote=True)}'>"
                        f"<input type='hidden' name='manifest' value='{html.escape(manifest, quote=True)}'>"
                        "<p>Opening GitHub to create the app...</p><button type='submit'>Continue to GitHub</button>"
                        "</form><script>document.getElementById('f').submit()</script>"
                    ),
                )
                return
            if url.path == "/callback":
                query = urllib.parse.parse_qs(url.query)
                if query.get("state", [""])[0] != state or not query.get("code"):
                    self.reply(
                        400,
                        "<p>Unexpected callback (state mismatch). Close this tab and retry.</p>",
                    )
                    return
                with open(output, "w", encoding="utf-8") as handle:
                    handle.write(query["code"][0])
                self.reply(
                    200, "<p>App created. You can close this tab and return to the terminal.</p>"
                )
                done.set()
                return
            self.reply(404, "<p>Not found</p>")

    return Handler


def main() -> int:
    """Serve until the callback arrives or the timeout passes (exit 1)."""
    port, manifest_file, form_url, state, output = sys.argv[1:6]
    timeout = float(sys.argv[6]) if len(sys.argv) > 6 else 600.0
    with open(manifest_file, encoding="utf-8") as handle:
        manifest = handle.read()
    done = threading.Event()
    server = http.server.HTTPServer(
        ("127.0.0.1", int(port)), make_handler(manifest, form_url, state, output, done)
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    finished = done.wait(timeout)
    server.shutdown()
    return 0 if finished else 1


if __name__ == "__main__":
    sys.exit(main())
