"""Exercise real downloads, including a cache serving different same-size bytes."""
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import urlsplit


class PublicReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="throttle-public-fixture-")
        self.addCleanup(self.directory.cleanup)
        self.stage = Path(self.directory.name)
        content = self.stage / "throttle"
        content.mkdir()
        (content / "Throttle-0.0.0.dmg").write_bytes(b"synthetic-candidate-A")
        (content / "appcast.xml").write_text("<sparkle:version>999</sparkle:version>\n")
        (content / "index.html").write_text('<a href="Throttle-0.0.0.dmg">Download</a>')
        self.corrupt_fresh_dmg = False
        self.corrupt_cached_appcast = False
        self.requests = []
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urlsplit(self.path)
                fixture.requests.append(self.path)
                filename = Path(parsed.path).name if parsed.path != "/throttle/" else "index.html"
                data = (content / filename).read_bytes()
                if filename.endswith(".dmg") and parsed.query and fixture.corrupt_fresh_dmg:
                    data = b"synthetic-candidate-B"  # Same length; HEAD cannot detect this.
                if filename == "appcast.xml" and not parsed.query and fixture.corrupt_cached_appcast:
                    data += b" "  # Same top build; comparing only that field misses drift.
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def verify(self):
        script = Path(__file__).resolve().parents[1] / "verify-public-release.sh"
        env = dict(os.environ, THROTTLE_VERIFY_SITE=f"http://127.0.0.1:{self.server.server_port}/throttle")
        return subprocess.run(["bash", str(script), str(self.stage)], env=env,
                              capture_output=True, text=True, timeout=20)

    def test_identical_downloads_pass(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        dmg_requests = [url for url in self.requests if ".dmg" in url]
        self.assertEqual(len(dmg_requests), 2)
        self.assertTrue(any("?cb=" in url for url in dmg_requests))

    def test_same_size_corrupt_fresh_dmg_fails(self):
        self.corrupt_fresh_dmg = True
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256", result.stderr)
        self.assertIn("?cb=", result.stderr)

    def test_cached_appcast_with_same_top_build_but_different_bytes_fails(self):
        self.corrupt_cached_appcast = True
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("edge-cached appcast differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
