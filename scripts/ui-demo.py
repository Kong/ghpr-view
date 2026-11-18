import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


TEST_ID = "MacOSUIUXTests/testCategorySwitchFiltersRowsAndAllRestoresGroups()"
STAGES = ["01-all", "02-reviews", "03-mentions", "04-my-prs", "05-all-restored"]
SCRIPT = Path(__file__).resolve()
ROOT = SCRIPT.parent.parent


def output(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def capture(directory):
    source_sha = output("git", "rev-parse", "HEAD")
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    pull_request = None
    if event_path:
        pull_request = json.loads(Path(event_path).read_text())["pull_request"]
        blocks = re.findall(r"^```ui-demo[ \t]*\r?\n(.*?)\r?\n```[ \t]*\r?$",
                            pull_request.get("body") or "", re.MULTILINE | re.DOTALL)
        if len(blocks) != 1 or json.loads(blocks[0]) != [{"name": "category-switch"}]:
            raise ValueError('Use one ui-demo block with [{"name":"category-switch"}].')
        if pull_request["head"]["sha"] != source_sha:
            raise ValueError("Checkout does not match the PR head.")

    bundle = directory / "demo.xcresult"
    attachments = directory / "attachments"
    artifact = directory / "artifact"
    artifact.mkdir(parents=True)
    log_path = directory / "xcodebuild.log"
    with log_path.open("w") as log:
        result = subprocess.run([
            "xcodebuild", "-project", "PRDashboard.xcodeproj", "-scheme", "PRDashboard",
            "-configuration", "UITesting", "-destination", "platform=macOS,arch=arm64",
            "-derivedDataPath", str(directory / "build"), "-resultBundlePath", str(bundle),
            "-parallel-testing-enabled", "NO", "CODE_SIGN_IDENTITY=-",
            "CODE_SIGNING_REQUIRED=YES", "CODE_SIGNING_ALLOWED=YES",
            "-only-testing:PRDashboardUITests/" + TEST_ID.removesuffix("()"), "test",
        ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise RuntimeError(f"xcodebuild exited {result.returncode}; see {log_path}")

    summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary",
                                "--path", str(bundle)))
    if summary["totalTestCount"] != 1 or summary["passedTests"] != 1:
        raise ValueError("Expected exactly one passing UI test.")
    output("xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
           "--output-path", str(attachments))
    manifest = json.loads((attachments / "manifest.json").read_text())
    records = [item for item in manifest if item["testIdentifier"] == TEST_ID]
    if len(records) != 1:
        raise ValueError(f"Expected an attachment record for {TEST_ID}.")

    frames = []
    for stage in STAGES:
        matches = [item for item in records[0]["attachments"]
                   if f"ghpr-demo-{stage}" in item["suggestedHumanReadableName"]]
        if len(matches) != 1 or matches[0]["isAssociatedWithFailure"]:
            raise ValueError(f"Expected one successful screenshot for {stage}.")
        frames.append(str(attachments / Path(matches[0]["exportedFileName"]).name))

    gif = artifact / "category-switch.gif"
    output("magick", "-delay", "140", *frames, "-resize", "720x900>",
           "-background", "#f0f0f0", "-gravity", "north", "-extent", "720x900",
           "-loop", "0", str(gif))
    if len(output("magick", "identify", "-format", "%s\n", str(gif)).splitlines()) != len(STAGES):
        raise ValueError("Unexpected GIF frame count.")
    evidence = {
        "sourceSHA": source_sha,
        "workflowRef": os.environ.get("GITHUB_WORKFLOW_REF"),
        "workflowSHA": os.environ.get("GITHUB_WORKFLOW_SHA"),
        "scriptSHA256": hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
        "gifSHA256": hashlib.sha256(gif.read_bytes()).hexdigest(),
        "runID": os.environ.get("GITHUB_RUN_ID"),
        "pullRequest": pull_request["number"] if pull_request else None,
        "testIdentifier": TEST_ID,
        "testResult": "passed",
        "capture": "XCTest screenshots of the fixture's native status-item popover",
        "frames": STAGES,
    }
    (artifact / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"{TEST_ID} passed; captured {len(frames)} frames from {source_sha}.")


if __name__ == "__main__":
    capture(Path(sys.argv[1]).resolve())
