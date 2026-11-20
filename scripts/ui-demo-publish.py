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
MAX_GIF_BYTES = 10 * 1024 * 1024
GIF_MAGIC = (b"GIF87a", b"GIF89a")
ARTIFACT_PREFIX = "ui-demo-"


class PublishError(RuntimeError):
    pass


def gh_api(*arguments, body=None):
    """Call `gh api` and return parsed JSON (or raw bytes for downloads)."""
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
    if not result.stdout:
        return None
    return json.loads(result.stdout)


def api_path(repo, suffix):
    return f"repos/{repo}/{suffix}"


def read_artifact_gif(repo, run_id):
    """Download the recorded artifact and return the GIF bytes."""
    artifacts = gh_api(api_path(repo, f"actions/runs/{run_id}/artifacts"), "--paginate")
    candidates = [
        item for item in artifacts.get("artifacts", [])
        if item.get("name", "").startswith(ARTIFACT_PREFIX) and not item.get("expired")
    ]
    if len(candidates) != 1:
        raise PublishError(
            f"expected exactly one live {ARTIFACT_PREFIX}* artifact, found {len(candidates)}"
        )
    with tempfile.TemporaryDirectory() as directory:
        archive = Path(directory) / "artifact.zip"
        result = subprocess.run(
            ["gh", "api", api_path(repo, f"actions/artifacts/{candidates[0]['id']}/zip")],
            capture_output=True,
        )
        if result.returncode != 0:
            raise PublishError("could not download the recorded artifact")
        archive.write_bytes(result.stdout)
        with zipfile.ZipFile(archive) as bundle:
            matches = [
                info for info in bundle.infolist()
                if Path(info.filename).name == "category-switch.gif" and not info.is_dir()
            ]
            if len(matches) != 1:
                raise PublishError(
                    f"expected exactly one category-switch.gif in the artifact, found {len(matches)}"
                )
            if matches[0].file_size > MAX_GIF_BYTES:
                raise PublishError(
                    f"recorded GIF is {matches[0].file_size} bytes, above the {MAX_GIF_BYTES} byte limit"
                )
            data = bundle.read(matches[0])
    if not data.startswith(GIF_MAGIC):
        raise PublishError("recorded artifact is not a GIF")
    return data


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
    path = f"pr-{pr_number}/category-switch.gif"
    contents = api_path(repo, "contents/" + path)
    existing = None
    try:
        existing = gh_api(contents, "-X", "GET", "-f", f"ref={ASSET_BRANCH}")
    except PublishError:
        existing = None
    body = {
        "message": f"Record UI demo for #{pr_number}",
        "content": base64.b64encode(data).decode(),
        "branch": ASSET_BRANCH,
    }
    if existing:
        body["sha"] = existing["sha"]
    response = gh_api(contents, "-X", "PUT", body=body)
    revision = response["commit"]["sha"]
    return (
        f"https://raw.githubusercontent.com/{repo}/{ASSET_BRANCH}/{path}?v={revision}"
    )


def upsert_comment(repo, pr_number, body_text):
    comments = gh_api(api_path(repo, f"issues/{pr_number}/comments"), "--paginate")
    mine = [item for item in comments if COMMENT_MARKER in (item.get("body") or "")]
    if len(mine) > 1:
        raise PublishError(f"found {len(mine)} previous UI demo comments; expected at most one")
    if mine:
        gh_api(
            api_path(repo, f"issues/comments/{mine[0]['id']}"),
            "-X", "PATCH",
            body={"body": body_text},
        )
        return "updated"
    gh_api(
        api_path(repo, f"issues/{pr_number}/comments"),
        "-X", "POST",
        body={"body": body_text},
    )
    return "created"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--default-branch", default="master")
    parser.add_argument("--dry-run", action="store_true",
                        help="verify and extract, but write nothing")
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

    pull_request = gh_api(api_path(options.repo, f"pulls/{pr_number}"))
    if pull_request.get("state") != "open":
        raise PublishError(f"pull request #{pr_number} is {pull_request.get('state')}")
    head_sha = pull_request["head"]["sha"]
    if head_sha != run.get("head_sha"):
        raise PublishError(
            f"run head {run.get('head_sha')} is not the current head {head_sha} of #{pr_number}"
        )
    labels = {label["name"] for label in pull_request.get("labels") or []}
    if "ui-demo" not in labels:
        raise PublishError(f"pull request #{pr_number} no longer carries the ui-demo label")
    if pull_request["head"]["repo"]["full_name"] != options.repo:
        raise PublishError("pull request head is not in this repository")

    data = read_artifact_gif(options.repo, options.run_id)
    if options.dry_run:
        print(
            f"dry run: #{pr_number} at {head_sha} is publishable; "
            f"artifact GIF is {len(data)} bytes"
        )
        return
    url = store_gif(options.repo, options.default_branch, pr_number, data)
    body = "\n".join([
        COMMENT_MARKER,
        f"![UI demo: menu bar category switching]({url})",
        "",
        f"UI Demo for `{head_sha}` from run `{options.run_id}`.",
        "",
        "The GIF covers only the menu bar category switching flow "
        "(All → Reviews → Mentions → My PRs → All restored). It does not show the "
        "settings panes, so it does not cover the Raft template editor.",
    ])
    outcome = upsert_comment(options.repo, pr_number, body)
    print(f"{outcome} UI demo comment on #{pr_number} for {head_sha}")


if __name__ == "__main__":
    try:
        main()
    except PublishError as error:
        print(f"ui-demo-publish: {error}", file=sys.stderr)
        sys.exit(1)
