"""Tests for scripts/ui-demo-publish.py.

Run with: python3 -m unittest discover -s scripts/tests -v
"""

import importlib.util
import json
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "ui-demo-publish.py"
spec = importlib.util.spec_from_file_location("ui_demo_publish", MODULE_PATH)
assert spec and spec.loader
ui_demo_publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui_demo_publish)

GIF = b"GIF89a" + b"\x00" * 32
SHA = "a" * 40
OTHER_SHA = "b" * 40


class FakeGH:
    """Stands in for `gh api`, keyed on the first path-shaped argument."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def __call__(self, arguments, body=None):
        arguments = list(arguments)
        self.calls.append((arguments, body))
        for (needle, result) in self.routes:
            needles = (needle,) if isinstance(needle, str) else needle
            if all(any(part in argument for argument in arguments) for part in needles):
                if isinstance(result, list):
                    # A list of pages, returned the way `--slurp` shapes them.
                    return json.dumps(result).encode()
                if isinstance(result, Exception):
                    raise result
                if isinstance(result, bytes):
                    return result
                return json.dumps(result).encode()
        raise ui_demo_publish.PublishError(f"unexpected gh api call: {arguments}")

    def paths(self):
        return [" ".join(arguments) for arguments, _ in self.calls]


def marker_comment(login, comment_id):
    return {
        "id": comment_id,
        "body": f"{ui_demo_publish.COMMENT_MARKER}\n![demo](x)",
        "user": {"login": login},
    }


class PagesTests(unittest.TestCase):
    def test_pages_are_flattened(self):
        fake = FakeGH([("issues/1/comments", [[{"id": 1}], [{"id": 2}]])])
        original = ui_demo_publish.run_gh
        ui_demo_publish.run_gh = fake
        try:
            items = ui_demo_publish.gh_api_pages("repos/o/r/issues/1/comments")
        finally:
            ui_demo_publish.run_gh = original
        self.assertEqual([item["id"] for item in items], [1, 2])

    def test_unreadable_json_becomes_publish_error(self):
        fake = FakeGH([("x", b"[{][{]")])
        original = ui_demo_publish.run_gh
        ui_demo_publish.run_gh = fake
        try:
            with self.assertRaises(ui_demo_publish.PublishError):
                ui_demo_publish.gh_api("repos/o/r/x")
        finally:
            ui_demo_publish.run_gh = original


class CommentTests(unittest.TestCase):
    def run_with(self, routes, call):
        fake = FakeGH(routes)
        original = ui_demo_publish.run_gh
        ui_demo_publish.run_gh = fake
        try:
            return call(fake)
        finally:
            ui_demo_publish.run_gh = original

    def test_human_comment_is_not_claimed_by_the_bot(self):
        routes = [("issues/1/comments", [[marker_comment("xiaocang", 11)]])]

        def call(_fake):
            return ui_demo_publish.bot_comments("o/r", 1)

        self.assertEqual(self.run_with(routes, call), [])

    def test_human_comment_is_never_patched(self):
        routes = [
            ("issues/1/comments", [[marker_comment("xiaocang", 11)]]),
            ("issues/1/comments", {"id": 99}),
        ]

        def call(fake):
            outcome = ui_demo_publish.upsert_comment("o/r", 1, ui_demo_publish.COMMENT_MARKER)
            return outcome, fake.paths()

        outcome, paths = self.run_with(routes, call)
        self.assertEqual(outcome, "created")
        self.assertFalse(any("issues/comments/11" in path for path in paths))

    def test_bot_comment_is_updated_in_place(self):
        routes = [
            ("issues/1/comments", [[marker_comment(ui_demo_publish.BOT_LOGIN, 21)]]),
            ("issues/comments/21", {"id": 21}),
        ]

        def call(fake):
            outcome = ui_demo_publish.upsert_comment("o/r", 1, ui_demo_publish.COMMENT_MARKER)
            return outcome, fake.paths()

        outcome, paths = self.run_with(routes, call)
        self.assertEqual(outcome, "updated")
        self.assertTrue(any("issues/comments/21" in path and "PATCH" in path for path in paths))
        self.assertFalse(any("PATCH" in path and "issue" == path.split("/")[0] for path in paths))

    def test_two_bot_comments_are_refused(self):
        routes = [
            ("issues/1/comments", [[
                marker_comment(ui_demo_publish.BOT_LOGIN, 21),
                marker_comment(ui_demo_publish.BOT_LOGIN, 22),
            ]]),
        ]

        def call(_fake):
            return ui_demo_publish.bot_comments("o/r", 1)

        with self.assertRaises(ui_demo_publish.PublishError):
            self.run_with(routes, call)


class ArtifactTests(unittest.TestCase):
    def run_with(self, routes, call):
        fake = FakeGH(routes)
        original = ui_demo_publish.run_gh
        ui_demo_publish.run_gh = fake
        try:
            return call(fake)
        finally:
            ui_demo_publish.run_gh = original

    def test_diagnostics_artifact_is_not_selected(self):
        routes = [("actions/runs/7/artifacts", [{"artifacts": [
            {"id": 1, "name": "ui-demo-diagnostics", "expired": False},
            {"id": 2, "name": f"ui-demo-{OTHER_SHA}", "expired": False},
            {"id": 3, "name": f"ui-demo-{SHA}", "expired": False},
        ]}])]

        def call(_fake):
            return ui_demo_publish.find_artifact("o/r", 7, SHA)

        self.assertEqual(self.run_with(routes, call)["id"], 3)

    def test_missing_artifact_is_refused(self):
        routes = [("actions/runs/7/artifacts", [{"artifacts": [
            {"id": 1, "name": "ui-demo-diagnostics", "expired": False},
        ]}])]

        def call(_fake):
            return ui_demo_publish.find_artifact("o/r", 7, SHA)

        with self.assertRaises(ui_demo_publish.PublishError):
            self.run_with(routes, call)


class StoreTests(unittest.TestCase):
    def run_with(self, routes, call):
        fake = FakeGH(routes)
        original = ui_demo_publish.run_gh
        ui_demo_publish.run_gh = fake
        try:
            return call(fake)
        finally:
            ui_demo_publish.run_gh = original

    def test_unchanged_gif_does_not_commit_again(self):
        routes = [
            ("git/ref/heads/ui-demo-assets", {"object": {"sha": SHA}}),
            ("contents/pr-1/category-switch.gif", {"sha": ui_demo_publish.blob_sha(GIF)}),
        ]

        def call(fake):
            url = ui_demo_publish.store_gif("o/r", "master", 1, GIF)
            return url, fake.paths()

        url, paths = self.run_with(routes, call)
        self.assertFalse(any("PUT" in path for path in paths))
        self.assertTrue(url.endswith(f"?v={ui_demo_publish.blob_sha(GIF)}"))

    def test_changed_gif_is_committed(self):
        routes = [
            ("git/ref/heads/ui-demo-assets", {"object": {"sha": SHA}}),
            (("contents/pr-1/category-switch.gif", "PUT"), {"commit": {"sha": "c" * 40}}),
            ("contents/pr-1/category-switch.gif", {"sha": OTHER_SHA}),
        ]

        def call(fake):
            url = ui_demo_publish.store_gif("o/r", "master", 1, GIF)
            return url, fake.paths()

        url, paths = self.run_with(routes, call)
        self.assertTrue(any("PUT" in path for path in paths))
        self.assertTrue(url.endswith("?v=" + "c" * 40))


class HeadTests(unittest.TestCase):
    def run_with(self, routes, call):
        fake = FakeGH(routes)
        original = ui_demo_publish.run_gh
        ui_demo_publish.run_gh = fake
        try:
            return call(fake)
        finally:
            ui_demo_publish.run_gh = original

    def pull_request(self, sha, labels=("ui-demo",), state="open"):
        return {
            "state": state,
            "labels": [{"name": label} for label in labels],
            "head": {"sha": sha, "repo": {"full_name": "o/r"}},
        }

    def test_current_head_passes(self):
        routes = [("pulls/1", self.pull_request(SHA))]

        def call(_fake):
            return ui_demo_publish.confirm_head("o/r", 1, SHA)

        self.assertEqual(self.run_with(routes, call)["head"]["sha"], SHA)

    def test_moved_head_is_refused(self):
        routes = [("pulls/1", self.pull_request(OTHER_SHA))]

        def call(_fake):
            return ui_demo_publish.confirm_head("o/r", 1, SHA)

        with self.assertRaises(ui_demo_publish.PublishError):
            self.run_with(routes, call)

    def test_removed_label_is_refused(self):
        routes = [("pulls/1", self.pull_request(SHA, labels=()))]

        def call(_fake):
            return ui_demo_publish.confirm_head("o/r", 1, SHA)

        with self.assertRaises(ui_demo_publish.PublishError):
            self.run_with(routes, call)

    def test_closed_pull_request_is_refused(self):
        routes = [("pulls/1", self.pull_request(SHA, state="closed"))]

        def call(_fake):
            return ui_demo_publish.confirm_head("o/r", 1, SHA)

        with self.assertRaises(ui_demo_publish.PublishError):
            self.run_with(routes, call)


if __name__ == "__main__":
    unittest.main()
