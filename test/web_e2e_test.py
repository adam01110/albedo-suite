"""Native web assets and overridable CLI packaging against an isolated daemon."""

import http.cookiejar
import re
import selectors
import subprocess
import unittest
import urllib.parse
import urllib.request

from harness import Albedo, Provider, text


class WebPackagingTests(unittest.TestCase):
    def setUp(self):
        provider = Provider(lambda _: text("ok"))
        self.addCleanup(provider.close)
        self.app = Albedo(provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def serve(self, dist=None):
        environment = dict(self.app.env)
        if dist is not None:
            environment["ALBEDO_WEB_DIST"] = str(dist)
        process = subprocess.Popen(
            [environment["ALBEDO_TEST_CLI"], "web", "--port", "0", "--no-open"],
            cwd=self.app.workspace,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        stdout = process.stdout
        assert stdout is not None

        def close():
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            stdout.close()

        self.addCleanup(close)
        with selectors.DefaultSelector() as ready:
            ready.register(stdout, selectors.EVENT_READ)
            self.assertTrue(ready.select(timeout=15), "web CLI did not announce a URL")
            line = stdout.readline()
        match = re.search(r"http://127\.0\.0\.1:\d+/\S*", line)
        self.assertIsNotNone(match, line)
        assert match is not None
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        with opener.open(match.group(), timeout=10) as response:
            document = response.read().decode()
            base = response.geturl()
        return opener, base, document

    def test_bundled_index_and_assets(self):
        opener, base, document = self.serve()
        self.assertIn("<html", document)
        assets = re.findall(r'(?:src|href)="(/assets/[^" ]+)"', document)
        self.assertTrue(assets, "bundled index has no built assets")
        for asset in assets:
            with opener.open(urllib.parse.urljoin(base, asset), timeout=10) as response:
                self.assertEqual(response.status, 200)
                self.assertTrue(response.read())

    def test_explicit_dist_overrides_packaged_default(self):
        dist = self.app.workspace / "web-override"
        dist.mkdir()
        (dist / "index.html").write_text("<html>explicit-web-dist</html>")
        _, _, document = self.serve(dist)
        self.assertIn("explicit-web-dist", document)
