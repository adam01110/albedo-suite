"""Tool images carry durable resource metadata through the real daemon stream."""

import base64
import struct
import unittest
import zlib

from harness import Albedo, Provider, operation_id, python, text


def image_bytes(pixels=b"\x00\xff\x00\x00\x00\xff\x00"):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


class ToolImagesTests(unittest.TestCase):
    def test_live_images_match_history_metadata_for_tools_and_pastes(self):
        # Upstream refuses to attach the same bytes twice in one cell.
        shown = [image_bytes(), image_bytes(b"\x00\x00\xff\x00\xff\x00\x00")]
        pasted = image_bytes(b"\xff\x00\x00\x00\x00\xff\x00")
        first, second = (base64.b64encode(image).decode() for image in shown)
        pending = [True]

        def script(_request):
            if pending and pending.pop():
                return python(f"import base64\nshow_image(base64.b64decode({first!r}))\nshow_image(base64.b64decode({second!r}))")
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
            for image, expected in zip(images, shown, strict=True):
                self.assertEqual(image["original_bytes"], len(expected))
                self.assertEqual((image["width"], image["height"]), (2, 1))
                self.assertNotIn("data", image)
                with app.api(image["reference"]["url"]) as response:
                    self.assertEqual(response.headers["Content-Type"], "image/png")
                    self.assertEqual(response.read(), expected)
            # A pasted input's live user event carries the durable image part.
            cursor = app.stream_page(session)
            with app.api(
                f"/sessions/{session}/inputs/{operation_id()}",
                {"kind": "message", "text": "Inspect this [Image #1]", "images": [{"mime_type": "image/png", "data": base64.b64encode(pasted).decode()}]},
                method="PUT",
            ):
                pass
            app.idle(session)
            streamed = app.stream_page(session, cursor)
            sent = [event["data"]["entry"] for event in streamed["events"] if event["type"] == "message" and event["data"]["entry"]["kind"] == "user"]
            self.assertEqual(len(sent), 1, streamed)
            pasted_images = [part["image"] for part in sent[0]["content"] if part["kind"] == "image"]
            self.assertEqual(len(pasted_images), 1)
            entry = [item for item in app.history(session)["items"] if item["kind"] == "user"][-1]
            self.assertEqual([part["image"] for part in entry["content"] if part["kind"] == "image"], pasted_images)
