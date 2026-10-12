"""Tool images carry durable resource metadata through the real daemon stream."""

import base64
import json
import struct
import unittest
import zlib
from urllib.error import HTTPError

from harness import Albedo, Provider, exclusive, python, text


def image_bytes():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\x00\xff\x00")) + chunk(b"IEND", b"")


@exclusive
class ToolImagesTests(unittest.TestCase):
    def test_live_multiple_images_replay_and_missing_resource(self):
        data = image_bytes()
        encoded = base64.b64encode(data).decode()
        pending = [True]

        def script(_request):
            if pending and pending.pop():
                return python(f"import base64\ndata = base64.b64decode({encoded!r})\nshow_image(data)\nshow_image(data)")
            return text("I see both images")

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            cursor = app.stream_page(session)
            app.prompt(session, "Show two test images").close()
            app.idle(session)
            streamed = app.stream_page(session, cursor)
            live = [event["data"] for event in streamed["events"] if event["type"] == "tool"]
            self.assertTrue(live, streamed)
            self.assertEqual(len(live[-1]["images"]), 2, live[-1])
            result = [entry for entry in app.history(session)["items"] if entry["kind"] == "tool_result"][-1]
            images = [part["image"] for part in result["content"] if part["kind"] == "image"]
            self.assertEqual(live[-1]["entry_id"], result["id"])
            self.assertEqual(live[-1]["images"], images)
            for image in images:
                self.assertEqual(image["original_bytes"], len(data))
                self.assertEqual((image["width"], image["height"]), (2, 1))
                self.assertNotIn("data", image)
                with app.api(image["reference"]["url"]) as response:
                    self.assertEqual(response.headers["Content-Type"], "image/png")
                    self.assertEqual(response.read(), data)
            with self.assertRaises(HTTPError) as failure:
                app.api(images[0]["reference"]["url"].replace("image-0", "image-99"))
            self.assertEqual(failure.exception.code, 404)
            failure.exception.close()
            app.restart()
            replay = [entry for entry in app.history(session)["items"] if entry["kind"] == "tool_result"][-1]
            self.assertEqual([part["image"] for part in replay["content"] if part["kind"] == "image"], images)
            with app.api(images[0]["reference"]["url"]) as response:
                self.assertEqual(response.read(), data)
