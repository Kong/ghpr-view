import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Window } from "happy-dom";

globalThis.__GHPR_TEST__ = true;
await import("../ghpr.user.js");

const { CLIENT, createGhprApp } = globalThis.GhprUserscript;

async function loadFixture(name) {
  const url = new URL(`./fixtures/${name}`, import.meta.url);
  return readFile(fileURLToPath(url), "utf8");
}

function jsonResponse(value, status = 200) {
  return { status, responseText: JSON.stringify(value) };
}

class FakeGM {
  constructor({
    snapshot,
    latestVersion = CLIENT.version,
    pageFailure = null,
    clientScopes = CLIENT.requested_scopes,
    paired = true
  } = {}) {
    this.snapshot = snapshot;
    this.latestVersion = latestVersion;
    this.pageFailure = pageFailure;
    this.clientScopes = clientScopes;
    this.storage = new Map([
      ["ghpr.bridge.port", 48120],
      ["ghpr.bridge.instance", "ghpr-test"]
    ]);
    if (paired) this.storage.set("ghpr.bridge.token", "cap_test");
    this.requests = [];
    this.opened = [];
    this.clipboard = [];
    this.commands = new Map();
  }

  async getValue(key, fallback) {
    return this.storage.has(key) ? this.storage.get(key) : fallback;
  }

  async setValue(key, value) {
    this.storage.set(key, value);
  }

  openInTab(url) {
    this.opened.push(url);
  }

  registerMenuCommand(label, callback) {
    this.commands.set(label, callback);
  }

  setClipboard(text) {
    this.clipboard.push(text);
  }

  async request(options) {
    this.requests.push(options);
    const url = new URL(options.url);
    if (url.pathname === "/.well-known/ghpr-browser-bridge") {
      return jsonResponse({
        protocol: "ghpr.browser-bridge/v1",
        instance_id: "ghpr-test",
        app_version: "1.0.0",
        official_userscript_version: this.latestVersion,
        api_versions: [1],
        pairing_required: true,
        github_surface_v2: true
      });
    }
    if (url.pathname === "/api/v1/client") {
      return jsonResponse({
        id: CLIENT.id,
        name: CLIENT.name,
        version: CLIENT.version,
        scopes: this.clientScopes,
        created_at: "2026-08-24T00:00:00Z",
        last_seen_at: "2026-08-24T00:00:00Z",
        revoked_at: null
      });
    }
    if (url.pathname === "/api/v1/page") {
      if (this.pageFailure) {
        return jsonResponse(
          { ok: false, error: { code: "page_failed", message: this.pageFailure } },
          503
        );
      }
      return jsonResponse(this.snapshot);
    }
    if (url.pathname === "/api/v1/actions") {
      return jsonResponse({ run: null, url: null, tags: [], rerun_count: null, event: null });
    }
    if (url.pathname === "/api/v1/pairings") {
      return jsonResponse({
        id: "pair_1",
        status: "approved",
        token: "cap_paired",
        scopes: this.clientScopes
      });
    }
    if (url.pathname === "/api/v1/slot-health") return jsonResponse({ ok: true });
    if (url.pathname === "/api/v1/surface-health") return jsonResponse({ ok: true });
    throw new Error(`Unhandled fake request: ${options.method} ${url.pathname}`);
  }
}

function basePage(pathname) {
  return {
    type: pathname.includes("/actions/runs/") ? "workflow_run" : "pull_request",
    key: `github:${pathname}`,
    repository: "acme/widgets",
    pr_number: 42,
    workflow_run_id: null,
    head_sha: "a".repeat(40)
  };
}

function makeSnapshot(pathname, overrides = {}) {
  return {
    page: basePage(pathname),
    pull_request: {
      id: 42,
      repository: "acme/widgets",
      number: 42,
      title: "Fixture PR",
      ci_status: "FAILURE",
      check_failure_count: 0
    },
    current_revision_subject: {
      type: "pull_request_revision",
      repository: "acme/widgets",
      pr_number: 42,
      base_sha: "a".repeat(40),
      head_sha: "b".repeat(40)
    },
    analyses: [],
    tags: [],
    runs: [],
    skills: [],
    contributions: [],
    findings: [],
    comment_shortcuts: [],
    github_surface_v2: true,
    ...overrides
  };
}

async function createWindow(fixtureName, pathname) {
  const html = await loadFixture(fixtureName);
  const window = new Window({ url: `https://github.com${pathname}` });
  window.document.write(html);
  window.document.close();
  return window;
}

async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
}

function openMenu(window) {
  const entry = window.document.getElementById("ghpr-header-entry");
  assert.ok(entry, "the compact ghpr entry is the only mounted control");
  const menu = entry.querySelector(".ghpr-header-menu");
  assert.equal(menu.hidden, true, "the menu stays closed until the entry is clicked");
  entry.querySelector(".ghpr-header-button").click();
  assert.equal(menu.hidden, false);
  return menu;
}

function reviewRun(findings, head = "c".repeat(40)) {
  return {
    id: "run_review",
    skill_id: "pr.review",
    status: "completed",
    completed_at: "2026-08-24T00:02:00Z",
    result: {
      code_review: {
        head_sha: head,
        overview_markdown: "One finding on the reviewed revision.",
        findings
      }
    }
  };
}

test("a PR page mounts only the compact entry and leaves GitHub checks untouched", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ snapshot: makeSnapshot(pathname) })
  });
  await app.start();
  await settle();

  assert.ok(window.document.getElementById("ghpr-header-entry"));
  assert.equal(window.document.getElementById("ghpr-operation-card"), null);
  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  assert.equal(window.document.querySelector("[data-ghpr-surface]"), null);
  for (const row of window.document.querySelectorAll("[data-testid='check-run-row']")) {
    assert.equal(row.querySelector("[data-ghpr-surface], .ghpr-check-tools"), null);
  }

  app.stop();
  window.close();
});

test("an unpaired page keeps Connect inside the closed menu", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ snapshot: makeSnapshot(pathname), paired: false })
  });
  await app.start();
  await settle();

  assert.equal(window.document.getElementById("ghpr-operation-card"), null);
  const menu = openMenu(window);
  assert.match(menu.textContent, /Connect this userscript/);
  assert.equal(menu.querySelector("[aria-label='Connect ghpr for GitHub']")?.textContent, "Connect ghpr");

  app.stop();
  window.close();
});

test("a failed page snapshot stays in the menu and Retry asks again", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({
    snapshot: makeSnapshot(pathname),
    pageFailure: "Browser Bridge timed out."
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const menu = openMenu(window);
  assert.match(menu.textContent, /Browser Bridge timed out/);
  const before = gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/page").length;
  [...menu.querySelectorAll("button")].find((button) => button.textContent === "Retry").click();
  await settle();
  const after = gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/page").length;
  assert.ok(after > before, "Retry must request the page again");

  app.stop();
  window.close();
});

test("review results stay collapsed, survive a refresh, and reset on another PR", async () => {
  const pathname = "/acme/widgets/pull/42";
  const finding = {
    id: "finding-1",
    title: "Handle the error",
    summary: "The failure is discarded.",
    severity: "warning",
    lifecycle: "outdated",
    subject: {
      file_path: "src/app.swift",
      start_line: 12,
      end_line: 12,
      head_sha: "c".repeat(40)
    }
  };
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({
    snapshot: makeSnapshot(pathname, {
      findings: [finding],
      runs: [reviewRun([], "c".repeat(40))]
    })
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const menu = openMenu(window);
  const toggle = menu.querySelector(".ghpr-review-results-toggle");
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
  assert.equal(menu.querySelector(".ghpr-review-results-body").hidden, true);
  assert.equal(menu.querySelector(".ghpr-review-finding"), null);

  toggle.click();
  const body = menu.querySelector(".ghpr-review-results-body");
  assert.equal(body.hidden, false);
  assert.match(body.textContent, /Handle the error/);
  assert.match(body.textContent, /Reviewed revision ccccccc/);
  assert.match(body.textContent, /Outdated/);

  await app.refresh();
  assert.equal(menu.hidden, false, "a refresh must not close the menu the user opened");
  assert.equal(menu.querySelector(".ghpr-review-results-body").hidden, false);

  window.history.pushState({}, "", "/acme/widgets/pull/99");
  await app.refresh();
  assert.equal(menu.hidden, true, "moving to another PR collapses the menu");
  assert.equal(app.reviewResultsOpen, false);
  assert.equal(app.showCodeAnnotations, false);

  app.stop();
  window.close();
});

test("code annotations stay off until asked, then mark only the added line", async () => {
  const pathname = "/acme/widgets/pull/42/files";
  const window = await createWindow("files-unified.html", pathname);
  const finding = {
    id: "finding-line",
    title: "Wrong side",
    summary: "Mark the added line.",
    severity: "error",
    lifecycle: "exact",
    subject: {
      file_path: "src/index.ts",
      side: "addition",
      start_line: 10,
      end_line: 10,
      head_sha: "b".repeat(40)
    }
  };
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({
      snapshot: makeSnapshot(pathname, {
        findings: [finding],
        runs: [reviewRun([], "b".repeat(40))]
      })
    })
  });
  await app.start();
  await settle();

  assert.equal(
    window.document.querySelector("[data-ghpr-surface]"),
    null,
    "annotations must not paint onto the diff before the user asks"
  );
  const menu = openMenu(window);
  menu.querySelector(".ghpr-review-results-toggle").click();
  const annotations = menu.querySelector(".ghpr-annotations-toggle");
  assert.equal(annotations.getAttribute("aria-pressed"), "false");
  annotations.click();
  await settle();

  const marked = window.document.querySelector("[data-ghpr-surface]");
  assert.ok(marked, "turning annotations on paints the matching diff line");
  const addedRow = window.document.querySelector("td.blob-num-addition[data-line-number='10']")?.closest("tr");
  const removedRow = window.document.querySelector("td.blob-num-deletion[data-line-number='10']")?.closest("tr");
  assert.ok(addedRow, "the fixture has an added line 10");
  assert.notEqual(removedRow, addedRow);
  assert.ok(
    addedRow.nextElementSibling?.querySelector("[data-ghpr-surface]") || addedRow.querySelector("[data-ghpr-surface]"),
    "the annotation belongs to the added line, not the deleted counterpart"
  );
  assert.equal(removedRow.querySelector("[data-ghpr-surface]"), null);
  assert.notEqual(removedRow.nextElementSibling, addedRow.nextElementSibling);

  annotations.click();
  await settle();
  assert.equal(window.document.querySelector("[data-ghpr-surface]"), null);

  app.stop();
  window.close();
});

test("failed-job rerun is a menu action and is absent when nothing failed", async () => {
  const pathname = "/acme/widgets/pull/42";
  const failing = await createWindow("conversation.html", pathname);
  const failingApp = createGhprApp({
    window: failing,
    document: failing.document,
    gm: new FakeGM({
      snapshot: makeSnapshot(pathname, {
        pull_request: { id: 42, repository: "acme/widgets", number: 42, ci_status: "FAILURE", check_failure_count: 2 }
      })
    })
  });
  await failingApp.start();
  const failingMenu = openMenu(failing);
  assert.match(failingMenu.textContent, /Re-run 2 failed jobs/);
  assert.equal(failing.document.querySelector("[data-ghpr-surface]"), null);

  const passing = await createWindow("conversation.html", pathname);
  const passingApp = createGhprApp({
    window: passing,
    document: passing.document,
    gm: new FakeGM({ snapshot: makeSnapshot(pathname) })
  });
  await passingApp.start();
  const passingMenu = openMenu(passing);
  assert.doesNotMatch(passingMenu.textContent, /Re-run/);

  failingApp.stop();
  passingApp.stop();
  failing.close();
  passing.close();
});

test("comment shortcuts render only when enabled and only prepare a draft", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({
    snapshot: makeSnapshot(pathname, {
      comment_shortcuts: [
        { id: "thanks", display_name: "Thanks", enabled: true },
        { id: "hidden", display_name: "Hidden", enabled: false }
      ]
    })
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  const menu = openMenu(window);
  assert.match(menu.textContent, /Thanks/);
  assert.doesNotMatch(menu.textContent, /Hidden/);
  [...menu.querySelectorAll("button")].find((button) => button.textContent === "Thanks").click();
  await settle();
  const action = gm.requests
    .map((request) => JSON.parse(request.data || "{}"))
    .find((body) => body.action?.kind === "prepare_comment_shortcut");
  assert.equal(action?.action?.shortcut_id, "thanks");
  assert.equal(action?.action?.kind, "prepare_comment_shortcut");

  app.stop();
  window.close();
});

test("an active run exposes View live log in the menu and not on the check row", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const gm = new FakeGM({
    snapshot: makeSnapshot(pathname, {
      runs: [{
        id: "run_live",
        skill_id: "ci.failure.explain",
        status: "running",
        started_at: "2026-08-24T00:00:01Z",
        completed_at: null
      }]
    })
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const row = window.document.querySelector("[data-testid='check-run-row']");
  assert.doesNotMatch(row?.textContent || "", /View log|Analyze/);
  const menu = openMenu(window);
  const view = [...menu.querySelectorAll("button")].find((button) => button.textContent === "View live log");
  assert.ok(view, "an active run must stay reachable from the menu");
  view.click();
  await settle();
  const action = gm.requests
    .map((request) => JSON.parse(request.data || "{}"))
    .find((body) => body.action?.kind === "open_detail");
  assert.deepEqual(action?.action, { kind: "open_detail", run_id: "run_live" });

  app.stop();
  window.close();
});

test("a running skill stays disabled in the menu and does not submit again", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({
    snapshot: makeSnapshot(pathname, {
      runs: [{
        id: "run_active",
        skill_id: "ci.failure.classify_flaky",
        status: "running",
        started_at: "2026-08-24T00:00:01Z"
      }]
    })
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const menu = openMenu(window);
  const busy = [...menu.querySelectorAll("button")].find((button) =>
    button.textContent.startsWith("Classify Flaky")
  );
  assert.equal(busy?.textContent, "Classify Flaky · Running");
  assert.equal(busy.disabled, true);
  busy.click();
  await settle();
  assert.equal(
    gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/actions").length,
    0,
    "a disabled running control must not submit another run"
  );

  app.stop();
  window.close();
});
