"""Pure release-number gate fixtures; HTTP responses injected, no network/signing."""
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

SPEC = importlib.util.spec_from_file_location(
    "verify_release_build", Path(__file__).resolve().parents[1] / "verify-release-build.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def feed(*versions):
    return ('<rss xmlns:sparkle="' + gate.SPARKLE + '"><channel>' + ''.join(
        '<item><sparkle:version>' + str(v) + '</sparkle:version></item>' for v in versions)
        + '</channel></rss>').encode()


class Response(io.BytesIO):
    def __init__(self, body, status=200, url=gate.FEED_URL):
        super().__init__(body)
        self.status = status
        self.url = url

    def geturl(self):
        return self.url


class ReleaseBuildGateTests(unittest.TestCase):
    def test_unsorted_feed_compares_global_maximum(self):
        self.assertEqual(gate.validate_feed(feed(200, 225, 210), "226"), 225)
        for candidate in ("225", "220", "200"):
            with self.subTest(candidate=candidate), self.assertRaises(gate.GateFailure):
                gate.validate_feed(feed(200, 225, 210), candidate)

    def test_malformed_empty_or_wrong_xml_refuses(self):
        for data in (b"", b"<rss>", b"<html>blocked</html>", b"<rss><channel/></rss>"):
            with self.subTest(data=data), self.assertRaises(gate.GateFailure):
                gate.validate_feed(data, "226")

    def test_real_legacy_dotted_history_does_not_block_new_integer_build(self):
        self.assertEqual(gate.validate_feed(feed("3.0.0", "223", "222"), "226"), 223)
        self.assertEqual(gate.validate_feed(feed("225.9", "223"), "226"), "225.9")

    def test_dotted_future_and_equivalent_builds_refuse(self):
        for version in ("226.0", "226.0.0", "226.1", "227.0", "000226.00"):
            with self.subTest(version=version), self.assertRaises(gate.GateFailure):
                gate.validate_feed(feed("223", version), "226")

    def test_unsupported_published_formats_refuse_even_in_old_items(self):
        for version in ("3.0beta", "3..0", "3.0.0.1", "+3", "-3", "3.0." + "9" * 19):
            with self.subTest(version=version), self.assertRaises(gate.GateFailure):
                gate.validate_feed(feed("223", version), "226")

    def test_missing_or_ambiguous_item_version_refuses_even_with_other_valid_item(self):
        valid = feed(225)
        for extra in (b"<item/>", b"<item><version>200</version></item>",
                      b"<item><sparkle:version>200</sparkle:version><sparkle:version>201</sparkle:version></item>"):
            with self.subTest(extra=extra), self.assertRaises(gate.GateFailure):
                gate.validate_feed(valid.replace(b"</channel>", extra + b"</channel>"), "226")

    def test_unknown_version_formats_refuse_instead_of_stripping_characters(self):
        for value in ("", "226beta", "2.26", "-226", "226 ", "9" * 19):
            with self.subTest(value=value), self.assertRaises(gate.GateFailure):
                gate.validate_feed(feed(225), value)
        with self.assertRaises(gate.GateFailure):
            gate.validate_feed(feed("225beta"), "226")

    def test_http_status_transport_and_redirect_errors_refuse(self):
        for status in (403, 500, 302):
            with self.subTest(status=status), self.assertRaises(gate.GateFailure):
                gate.fetch_feed(lambda *a, **k: Response(feed(225), status=status))
        for error in (urllib.error.HTTPError(gate.FEED_URL, 403, "forbidden", {}, None),
                      urllib.error.URLError("offline"), TimeoutError()):
            with self.subTest(error=error), self.assertRaises(gate.GateFailure):
                with patch.object(gate.urllib.request, "urlopen", side_effect=error):
                    gate.fetch_feed()
        with self.assertRaises(gate.GateFailure):
            gate.fetch_feed(lambda *a, **k: Response(feed(225), url="https://example.invalid/challenge"))

    def test_successful_http_fixture_is_bounded_and_validated(self):
        payload = gate.fetch_feed(lambda *a, **k: Response(feed(224, 225)))
        self.assertEqual(gate.validate_feed(payload, "226"), 225)
        with self.assertRaises(gate.GateFailure):
            gate.fetch_feed(lambda *a, **k: Response(b"x" * (gate.MAXIMUM_FEED_BYTES + 1)))

    def test_xml_entity_declarations_are_not_accepted(self):
        with self.assertRaises(gate.GateFailure):
            gate.validate_feed(b'<!DOCTYPE rss [<!ENTITY version "225">]>' + feed(225), "226")
        with self.assertRaises(gate.GateFailure):
            gate.validate_feed(feed(225).decode().encode("utf-16"), "226")

    def test_cli_returns_nonzero_and_does_not_fetch_invalid_candidate(self):
        with patch.object(gate, "fetch_feed") as fetch, patch("sys.stderr", new=io.StringIO()):
            self.assertEqual(gate.main(["--candidate", "226bad"]), 65)
            fetch.assert_not_called()
        with patch.object(gate, "fetch_feed", side_effect=gate.GateFailure("unavailable")), \
                patch("sys.stderr", new=io.StringIO()):
            self.assertEqual(gate.main(["--candidate", "226"]), 65)


if __name__ == "__main__":
    unittest.main()
