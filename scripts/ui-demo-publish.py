#!/usr/bin/env python3
"""Publish the recorded UI demo GIF as a pull request comment.

This runs from the default branch after the "UI Demo" recording workflow
finishes. It never executes code from the pull request or from the recorded
artifact: the only value taken from the artifact is one GIF file, checked for
its magic bytes and size and stored under a fixed name in this repository.

Usage: ui-demo-publish.py --repo <owner/name> --run-id <id>
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

RECORD_WORKFLOW_PATH = ".github/workflows/ui-demo.yml"
ASSET_BRANCH = "ui-demo-assets"
COMMENT_MARKER = "<!-- ghpr-ui-demo:category-switch -->"
BOT_LOGIN = "github-actions[bot]"
MAX_GIF_BYTES = 10 * 1024 * 1024
GIF_MAGIC = (b"GIF87a", b"GIF89a")
GIF_NAME = "category-switch.gif"


class PublishError(RuntimeError):
    pass


def run_gh(arguments, body=None):
    """Run `gh api` and return stdout bytes. Patched by the tests."""
    command = ["gh", "api", *arguments]
    payload = None
    if body is not None:
        command += ["--input", "-"]
        payload = json.dumps(body).encode()
    result = subprocess.run(command, input=payload, capture_output=True)
    if result.returncode != 0:
        raise PublishError(
            f"gh api {' '.join(arguments)} failed: "
            f"{result.stderr.decode(errors='replace').strip()}"
        )
    return result.stdout


def gh_api(*arguments, body=None):
    """Return parsed JSON from a single `gh api` call."""
    stdout = run_gh(arguments, body=body)
    if not stdout:
        return None
    try:
        return json.loads(stdout)
    except json.JSONDecodeError as error:
        raise PublishError(f"gh api returned unreadable JSON: {error}") from error


def gh_api_pages(*arguments):
    """Return every page of a paginated `gh api` call as one flat list."""
    stdout = run_gh(["--paginate", "--slurp", *arguments])
    try:
        pages = json.loads(stdout or b"[]")
    except json.JSONDecodeError as error:
        raise PublishError(f"gh api --paginate returned unreadable JSON: {error}") from error
    items = []
    for page in pages:
        if isinstance(page, list):
            items.extend(page)
        else:
            items.append(page)
    return items


def api_path(repo, suffix):
    return f"repos/{repo}/{suffix}"


def find_artifact(repo, run_id, head_sha):
    """Return the artifact recorded for this run and head, if exactly one exists."""
    artifacts = []
    for page in gh_api_pages(api_path(repo, f"actions/runs/{run_id}/artifacts")):
        artifacts.extend(page.get("artifacts", []))
    expected = f"ui-demo-{head_sha}"
    candidates = [
        item for item in artifacts
        if item.get("name") == expected and not item.get("expired")
    ]
    if len(candidates) != 1:
        raise PublishError(
            f"expected exactly one live {expected} artifact, found {len(candidates)}"
        )
    return candidates[0]


def read_artifact_gif(repo, run_id, head_sha):
    """Download the recorded artifact and return the GIF bytes."""
    artifact = find_artifact(repo, run_id, head_sha)
    with tempfile.TemporaryDirectory() as directory:
        archive = Path(directory) / "artifact.zip"
        archive.write_bytes(run_gh([api_path(repo, f"actions/artifacts/{artifact['id']}/zip")]))
        try:
            with zipfile.ZipFile(archive) as bundle:
                matches = [
                    info for info in bundle.infolist()
                    if Path(info.filename).name == GIF_NAME and not info.is_dir()
                ]
                if len(matches) != 1:
                    raise PublishError(
                        f"expected exactly one {GIF_NAME} in the artifact, found {len(matches)}"
                    )
                if matches[0].file_size > MAX_GIF_BYTES:
                    raise PublishError(
                        f"recorded GIF is {matches[0].file_size} bytes, "
                        f"above the {MAX_GIF_BYTES} byte limit"
                    )
                data = bundle.read(matches[0])
        except zipfile.BadZipFile as error:
            raise PublishError(f"artifact is not a readable zip: {error}") from error
    if not data.startswith(GIF_MAGIC):
        raise PublishError("recorded artifact is not a GIF")
    return data


def blob_sha(data):
    """Return the git blob SHA of `data`, matching what the contents API reports."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def ensure_asset_branch(repo, default_branch):
    try:
        gh_api(api_path(repo, "git/ref/heads/" + ASSET_BRANCH))
        return
    except PublishError:
        pass
    base = gh_api(api_path(repo, "git/ref/heads/" + default_branch))
    gh_api(
        api_path(repo, "git/refs"),
        "-X", "POST",
        body={"ref": "refs/heads/" + ASSET_BRANCH, "sha": base["object"]["sha"]},
    )


def store_gif(repo, default_branch, pr_number, data):
    """Store the GIF on the asset branch and return its public raw URL."""
    ensure_asset_branch(repo, default_branch)
    path = f"pr-{pr_number}/{GIF_NAME}"
    contents = api_path(repo, "contents/" + path)
    try:
        existing = gh_api(contents, "-X", "GET", "-f", f"ref={ASSET_BRANCH}")
    except PublishError:
        existing = None

    revision = blob_sha(data)
    if not (existing and existing.get("sha") == revision):
        body = {
            "message": f"Record UI demo for #{pr_number}",
            "content": base64.b64encode(data).decode(),
            "branch": ASSET_BRANCH,
        }
        if existing:
            body["sha"] = existing["sha"]
        response = gh_api(contents, "-X", "PUT", body=body)
        revision = response["commit"]["sha"]
    return f"https://raw.githubusercontent.com/{repo}/{ASSET_BRANCH}/{path}?v={revision}"


def bot_comments(repo, pr_number):
    """Return this workflow's own comments on the pull request, never a human's."""
    comments = gh_api_pages(api_path(repo, f"issues/{pr_number}/comments"))
    mine = [
        item for item in comments
        if COMMENT_MARKER in (item.get("body") or "")
        and (item.get("user") or {}).get("login") == BOT_LOGIN
    ]
    if len(mine) > 1:
        raise PublishError(
            f"found {len(mine)} previous UI demo comments from {BOT_LOGIN}; expected at most one"
        )
    return mine


def upsert_comment(repo, pr_number, body_text):
    mine = bot_comments(repo, pr_number)
    if mine:
        gh_api(
            api_path(repo, f"issues/comments/{mine[0]['id']}"),
            "-X", "PATCH",
            body={"body": body_text},
        )
        return "updated"
    gh_api(api_path(repo, f"issues/{pr_number}/comments"), "-X", "POST", body={"body": body_text})
    return "created"


def confirm_head(repo, pr_number, expected_sha):
    pull_request = gh_api(api_path(repo, f"pulls/{pr_number}"))
    if pull_request.get("state") != "open":
        raise PublishError(f"pull request #{pr_number} is {pull_request.get('state')}")
    if pull_request["head"]["sha"] != expected_sha:
        raise PublishError(
            f"pull request #{pr_number} moved to {pull_request['head']['sha']}; "
            f"not publishing the older {expected_sha} recording"
        )
    labels = {label["name"] for label in pull_request.get("labels") or []}
    if "ui-demo" not in labels:
        raise PublishError(f"pull request #{pr_number} no longer carries the ui-demo label")
    if pull_request["head"]["repo"]["full_name"] != repo:
        raise PublishError("pull request head is not in this repository")
    return pull_request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--default-branch", default="master")
    parser.add_argument("--dry-run", action="store_true",
                        help="verify and extract, but write nothing")
    parser.add_argument("--note", default=None,
                        help="extra sentence to append, for a manual publish")
    options = parser.parse_args()

    if not os.environ.get("GH_TOKEN"):
        raise PublishError("GH_TOKEN is not set")

    run = gh_api(api_path(options.repo, f"actions/runs/{options.run_id}"))
    if run.get("event") != "pull_request":
        raise PublishError(f"run {options.run_id} was not triggered by a pull request")
    if run.get("conclusion") != "success":
        raise PublishError(f"run {options.run_id} concluded {run.get('conclusion')}")
    if run.get("path") != RECORD_WORKFLOW_PATH:
        raise PublishError(f"run {options.run_id} came from {run.get('path')}")
    pull_requests = run.get("pull_requests") or []
    if len(pull_requests) != 1:
        raise PublishError(f"run {options.run_id} is not tied to exactly one pull request")
    pr_number = pull_requests[0]["number"]

    run_sha = run.get("head_sha")
    confirm_head(options.repo, pr_number, run_sha)

    data = read_artifact_gif(options.repo, options.run_id, run_sha)
    if options.dry_run:
        print(
            f"dry run: #{pr_number} at {run_sha} is publishable; "
            f"artifact GIF is {len(data)} bytes"
        )
        return

    # The head may have moved while the artifact was downloading.
    confirm_head(options.repo, pr_number, run_sha)
    url = store_gif(options.repo, options.default_branch, pr_number, data)
    confirm_head(options.repo, pr_number, run_sha)
    body = "\n".join([
        COMMENT_MARKER,
        f"![UI demo: menu bar category switching]({url})",
        "",
        f"UI Demo for `{run_sha}` from run `{options.run_id}`.",
        "",
        "The GIF covers only the menu bar category switching flow "
        "(All → Reviews → Mentions → My PRs → All restored). It does not show the "
        "settings panes, so it does not cover the Raft template editor.",
    ])
    if options.note:
        body += "\n\n" + options.note
    outcome = upsert_comment(options.repo, pr_number, body)
    print(f"{outcome} UI demo comment on #{pr_number} for {run_sha}")


if __name__ == "__main__":
    try:
        main()
    except PublishError as error:
        print(f"ui-demo-publish: {error}", file=sys.stderr)
        sys.exit(1)
