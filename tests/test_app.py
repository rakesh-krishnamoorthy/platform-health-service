import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

from app import app


class AppTests(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_home(self):
        resp = self.client.get("/")
        self.assertEqual(resp.status_code, 200)
        self.assertIn(b"Hello", resp.data)

    def test_health(self):
        resp = self.client.get("/health")
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.get_json(), {"status": "ok"})

    def test_unknown_path_returns_404(self):
        resp = self.client.get("/does-not-exist")
        self.assertEqual(resp.status_code, 404)


if __name__ == "__main__":
    unittest.main()
