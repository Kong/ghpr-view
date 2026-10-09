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
    discoveryV2 = true,
    latestVersion = CLIENT.version,
    pageFailure = null,
    clientScopes = CLIENT.requested_scopes
  } = {}) {
    this.snapshot = snapshot;
    this.discoveryV2 = discoveryV2;
    this.latestVersion = latestVersion;
    this.pageFailure = pageFailure;
    this.clientScopes = clientScopes;
    this.storage = new Map([
      ["ghpr.bridge.port", 48120],
      ["ghpr.bridge.instance", "ghpr-test"],
      ["ghpr.bridge.token", "cap_test"]
    ]);
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
        github_surface_v2: this.discoveryV2
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
    if (url.pathname === "/api/v1/subjects/resolve") {
      const body = JSON.parse(options.data);
      if (body.type === "workflow_job") {
        return jsonResponse({
          repository: body.repository,
          workflow_run_id: 1001,
          workflow_attempt: 2,
          workflow_job_id: body.workflow_job_id,
          head_sha: "a".repeat(40)
        });
      }
      return jsonResponse({
        repository: body.repository,
        pr_number: body.pr_number,
        base_sha: "b".repeat(40),
        head_sha: "a".repeat(40)
      });
    }
    if (url.pathname === "/api/v1/actions") {
      const body = JSON.parse(options.data);
      return jsonResponse({ run: null, url: null, tags: [], rerun_count: null, event: null });
    }
    if (url.pathname === "/api/v1/slot-health") return jsonResponse({ ok: true });
    if (url.pathname === "/api/v1/surface-health") return jsonResponse({ ok: true });
    throw new Error(`Unhandled fake request: ${options.method} ${url.pathname}`);
  }
}

function basePage(pathname) {
  return {
    type: pathname.includes("/actions/runs/") ? "workflow_run" : "pull_request",
    key: "github:acme/widgets:pr:42",
    repository: "acme/widgets",
    pr_number: 42,
    workflow_run_id: null,
    head_sha: "a".repeat(40)
  };
}

function makeSnapshot(pathname, overrides = {}) {
  return {
    page: basePage(pathname),
    pull_request: { id: 42, repository: "acme/widgets", number: 42, title: "Fixture PR", ci_status: "FAILURE" },
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

function jobRun({ skillID, runId, jobId, status, result }) {
  return {
    id: `run_${skillID}_${jobId}`,
    skill_id: skillID,
    subject: { type: "workflow_job", workflow_run_id: runId, workflow_job_id: jobId },
    status,
    started_at: "2026-08-24T00:00:00Z",
    completed_at: status === "completed" ? "2026-08-24T00:01:00Z" : null,
    result: result || null
  };
}

test("v2: four failed Checks rows render isolated per-job state (flaky/related/untouched/investigating)", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    runs: [
      jobRun({
        skillID: "ci.failure.classify_flaky",
        runId: 1001,
        jobId: 2001,
        status: "completed",
        result: { payload: { verdict: "likely_flaky", confidence: 0.81, flaky_evidence: ["3 similar failures on main"], suggested_action: "Re-run" } }
      }),
      jobRun({
        skillID: "ci.failure.classify_flaky",
        runId: 1001,
        jobId: 2002,
        status: "completed",
        result: { payload: { verdict: "likely_related", confidence: 0.64, flaky_evidence: [], suggested_action: "Fix lint" } }
      }),
      jobRun({
        skillID: "ci.failure.classify_flaky",
        runId: 1001,
        jobId: 2004,
        status: "running",
        result: null
      })
    ]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const rows = [...window.document.querySelectorAll("[data-testid='check-run-row']")];
  const unitTestRow = rows.find((row) => row.dataset.checkName === "unit-test");
  const lintRow = rows.find((row) => row.dataset.checkName === "lint");
  const buildRow = rows.find((row) => row.dataset.checkName === "build");
  const e2eRow = rows.find((row) => row.dataset.checkName === "e2e");

  assert.match(unitTestRow.querySelector("[data-ghpr-surface]")?.textContent || "", /Likely flaky/);
  assert.match(lintRow.querySelector("[data-ghpr-surface]")?.textContent || "", /Likely related/);
  assert.equal(buildRow.querySelector("[data-ghpr-surface]"), null, "untouched success row must stay native");
  assert.match(e2eRow.querySelector("[data-ghpr-surface]")?.textContent || "", /Investigating/);

  // Job isolation: unit-test's verdict never leaks onto lint's row or vice versa.
  assert.doesNotMatch(lintRow.textContent, /Likely flaky/);
  assert.doesNotMatch(unitTestRow.textContent, /Likely related/);

  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  assert.equal(window.document.getElementById("ghpr-header-entry"), null);

  app.stop();
  window.close();
});

test("v2: selecting a failed Checks row opens exactly one CI Insight panel scoped to that job", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    runs: [
      jobRun({
        skillID: "ci.failure.explain",
        runId: 1001,
        jobId: 2001,
        status: "completed",
        result: {
          payload: {
            why_it_failed: "Flaky network call.",
            relevant_evidence: ["retry #3 succeeded"],
            suggested_action: "Re-run"
          }
        }
      })
    ]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const unitTestRow = [...window.document.querySelectorAll("[data-testid='check-run-row']")]
    .find((row) => row.dataset.checkName === "unit-test");
  const explainButton = [...unitTestRow.querySelectorAll("button")].find((b) => b.textContent === "Explain");
  assert.ok(explainButton, "Explain action must be present on the unresolved failing row");
  explainButton.click();
  await settle();
  app.render();

  const panels = [...window.document.querySelectorAll("[data-ghpr-surface='github.pr.checks.job.insight']")];
  assert.equal(panels.length, 1, "only one CI Insight panel may be mounted at a time");
  assert.match(panels[0].textContent, /Flaky network call/);
  assert.equal(panels[0].dataset.layout, "checks");
  assert.ok(panels[0].querySelector(".ghpr-ci-result-rail"), "Checks insight must keep the result/actions rail inline");
  assert.ok([...panels[0].querySelectorAll("button")].some((button) => button.textContent === "Re-run failed jobs"));

  app.stop();
  window.close();
});

test("v2: Failed checks opens the first failure and navigates between failures in-page", async () => {
  const pathname = "/acme/widgets/pull/42/checks?ghpr_check=first";
  const window = await createWindow("checks.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    runs: [
      {
        id: "run-explain-current",
        skill_id: "ci.failure.explain",
        subject: { type: "legacy_page", page: basePage(pathname) },
        status: "completed",
        completed_at: "2026-08-24T00:03:00Z",
        result: {
          payload: {
            why_it_failed: "Unit tests could not connect to Postgres.",
            relevant_evidence: ["connection refused"],
            _ghpr_job: {
              repository: "acme/widgets",
              workflow_run_id: "1001",
              workflow_job_id: "2001",
              workflow_name: "unit-test"
            }
          }
        }
      },
      jobRun({
        skillID: "ci.failure.explain",
        runId: 1001,
        jobId: 2002,
        status: "completed",
        result: {
          payload: {
            why_it_failed: "Lint rejected an unused import.",
            relevant_evidence: []
          }
        }
      }),
      jobRun({
        skillID: "ci.failure.explain",
        runId: 9999,
        jobId: 9999,
        status: "completed",
        result: {
          payload: {
            why_it_failed: "An old job failed for a stale reason.",
            relevant_evidence: []
          }
        }
      })
    ]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const rows = [...window.document.querySelectorAll("[data-testid='check-run-row']")];
  const unitTestRow = rows.find((row) => row.dataset.checkName === "unit-test");
  const lintRow = rows.find((row) => row.dataset.checkName === "lint");
  const e2eRow = rows.find((row) => row.dataset.checkName === "e2e");
  const summary = window.document.querySelector(
    "[data-ghpr-surface='github.pr.checks.summary']"
  );
  assert.match(summary?.textContent || "", /Unit tests could not connect to Postgres/);
  assert.match(summary?.textContent || "", /Lint rejected an unused import/);
  assert.doesNotMatch(summary?.textContent || "", /stale reason/);
  assert.equal(
    unitTestRow.querySelector(".ghpr-job-reason")?.textContent,
    "Unit tests could not connect to Postgres."
  );
  assert.equal(
    lintRow.querySelector(".ghpr-job-reason")?.textContent,
    "Lint rejected an unused import."
  );
  assert.equal(e2eRow.querySelector(".ghpr-job-reason"), null);
  let panel = window.document.querySelector("[data-ghpr-surface='github.pr.checks.job.insight']");
  assert.equal(unitTestRow.nextElementSibling, panel);
  assert.match(panel.querySelector(".ghpr-item-navigator-count")?.textContent || "", /1 of 3 failed checks/);
  assert.equal(panel.querySelector("[data-action-id='previous-failed-check']")?.disabled, true);

  panel.querySelector("[data-action-id='next-failed-check']").click();
  panel = window.document.querySelector("[data-ghpr-surface='github.pr.checks.job.insight']");
  assert.equal(lintRow.nextElementSibling, panel);
  assert.match(panel.querySelector(".ghpr-item-navigator-count")?.textContent || "", /2 of 3 failed checks/);
  assert.notEqual(new URLSearchParams(window.location.search).get("ghpr_check"), "first");

  panel.querySelector("[data-action-id='next-failed-check']").click();
  panel = window.document.querySelector("[data-ghpr-surface='github.pr.checks.job.insight']");
  assert.equal(e2eRow.nextElementSibling, panel);
  assert.match(panel.querySelector(".ghpr-item-navigator-count")?.textContent || "", /3 of 3 failed checks/);
  assert.equal(panel.querySelector("[data-action-id='next-failed-check']")?.disabled, true);

  app.stop();
  window.close();
});

test("v2: Checks title expands the matching suite and shows its reason beside the job", async () => {
  const pathname = "/acme/widgets/pull/42/checks?ghpr_check=first";
  const window = await createWindow("checks.html", pathname);
  const unitTestRow = window.document.querySelector("[data-check-name='unit-test']");
  for (const row of window.document.querySelectorAll("[data-testid='check-run-row']")) {
    row.remove();
  }
  const toggle = window.document.createElement("button");
  toggle.setAttribute("aria-expanded", "false");
  toggle.textContent = "unit-test";
  window.document.querySelector("#checks_tab .Box-header").after(toggle);
  toggle.addEventListener("click", () => {
    toggle.setAttribute("aria-expanded", "true");
    toggle.after(unitTestRow);
  });
  const snapshot = makeSnapshot(pathname, {
    runs: [{
      id: "run-explain-page",
      skill_id: "ci.failure.explain",
      subject: { type: "legacy_page", page: basePage(pathname) },
      status: "completed",
      completed_at: "2026-08-24T00:03:00Z",
      result: {
        payload: {
          why_it_failed: "The latest failed job timed out waiting for its database.",
          relevant_evidence: ["readiness probe exceeded 60 seconds"],
          _ghpr_job: {
            repository: "acme/widgets",
            workflow_run_id: "1001",
            workflow_job_id: "2001",
            workflow_name: "unit-test"
          }
        }
      }
    }]
  });
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ snapshot })
  });
  await app.start();
  await settle();
  await new Promise((resolve) => window.setTimeout(resolve, 300));
  await settle();

  const summary = window.document.querySelector(
    "[data-ghpr-surface='github.pr.checks.summary']"
  );
  assert.match(summary?.textContent || "", /timed out waiting for its database/);
  assert.equal(toggle.getAttribute("aria-expanded"), "true");
  assert.equal(
    unitTestRow.querySelector(".ghpr-job-reason")?.textContent,
    "The latest failed job timed out waiting for its database."
  );

  app.stop();
  window.close();
});

test("v2: Checks row health stays independent from summary health and failure count", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const root = window.document.querySelector("#checks_tab");
  const passingRow = root.querySelector("[data-check-name='build']");
  for (const row of root.querySelectorAll("[data-testid='check-run-row']")) {
    if (row !== passingRow) row.remove();
  }
  const gm = new FakeGM({ snapshot: makeSnapshot(pathname) });
  const app = createGhprApp({ window, document: window.document, gm });
  const health = (surface) => gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/surface-health")
    .map((request) => JSON.parse(request.data))
    .filter((report) => report.surface === surface)
    .at(-1)?.state;
  const rowsSurface = "github.pr.checks.job.trailing";
  const summarySurface = "github.pr.checks.summary";
  try {
    await app.start();
    await settle();
    assert.equal(health(rowsSurface), "healthy", "passing native rows are valid anchors");

    passingRow.remove();
    app.render();
    await settle();
    assert.equal(health(rowsSurface), "missing", "missing rows must report DOM drift or pending loading");
    assert.equal(health(summarySurface), "healthy", "a mounted summary must not mask missing row anchors");

    root.append(passingRow);
    app.render();
    await settle();
    assert.equal(health(rowsSurface), "healthy", "newly loaded rows must restore row health");

    window.document.querySelector("main").remove();
    app.render();
    await settle();
    assert.equal(health(rowsSurface), "missing", "losing the Checks container also loses row anchors");
    assert.equal(health(summarySurface), "missing", "losing the Checks container loses the summary anchor");
  } finally {
    app.stop();
    window.close();
  }
});

test("v2: Checks summary always mounts with bounded discovery when suites are collapsed and there are no explanations", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const { document } = window;

  // Simulate a Checks page with no legacy summary anchor: rename the only
  // native container so `#checks_tab`/`.checks-listing`/`#partial-pull-checks`
  // no longer match, forcing the fallback to the unique `<main>`.
  const nativeContainer = document.querySelector("#checks_tab");
  nativeContainer.removeAttribute("id");
  for (const row of document.querySelectorAll("[data-testid='check-run-row']")) row.remove();

  const clicks = { unit: 0, lint: 0, managed: 0 };
  function collapsedRow(name, runId, jobId) {
    const row = document.createElement("div");
    row.setAttribute("data-testid", "check-run-row");
    row.setAttribute("data-check-name", name);
    row.innerHTML = `<span>${name}</span><strong>Failed</strong>`;
    const link = document.createElement("a");
    link.setAttribute("href", `/acme/widgets/actions/runs/${runId}/job/${jobId}`);
    link.setAttribute("title", "View details");
    link.textContent = "Details";
    row.appendChild(link);
    return row;
  }
  function suiteToggle(label, row, tracker) {
    const toggle = document.createElement("button");
    toggle.setAttribute("aria-expanded", "false");
    toggle.className = "js-check-suite-toggle";
    toggle.textContent = label;
    toggle.addEventListener("click", () => {
      tracker.count += 1;
      toggle.setAttribute("aria-expanded", "true");
      toggle.after(row);
    });
    return toggle;
  }
  const unitTracker = { count: 0 };
  const lintTracker = { count: 0 };
  const unitRow = collapsedRow("unit-test", 1001, 2001);
  const lintRow = collapsedRow("lint", 1001, 2002);
  const unitToggle = suiteToggle("unit-test", unitRow, unitTracker);
  const lintToggle = suiteToggle("lint", lintRow, lintTracker);
  nativeContainer.querySelector(".Box-header").after(unitToggle, lintToggle);

  // A ghpr-managed collapsed control inside the root must never be treated
  // as a discoverable native suite.
  const managedWrap = document.createElement("div");
  managedWrap.setAttribute("data-ghpr-managed", "");
  const managedToggle = document.createElement("button");
  managedToggle.setAttribute("aria-expanded", "false");
  managedToggle.textContent = "ghpr-managed-toggle";
  managedToggle.addEventListener("click", () => { clicks.managed += 1; });
  managedWrap.appendChild(managedToggle);
  nativeContainer.appendChild(managedWrap);

  // A collapsed control outside the discovered root must never be clicked.
  const outsideToggle = document.createElement("button");
  outsideToggle.setAttribute("aria-expanded", "false");
  outsideToggle.textContent = "unrelated-outside-toggle";
  document.body.appendChild(outsideToggle);

  const snapshot = makeSnapshot(pathname, {
    pull_request: { id: 42, repository: "acme/widgets", number: 42, title: "Fixture PR", ci_status: "FAILURE", check_failure_count: 2 },
    runs: []
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document, gm });
  await app.start();
  await settle();

  let summary = document.querySelector("[data-ghpr-surface='github.pr.checks.summary']");
  assert.ok(summary, "the ghpr CI summary must mount even with no explanations, no legacy anchor, and collapsed suites");
  assert.equal(summary.querySelector(".ghpr-ci-summary-title")?.textContent, "ghpr CI summary");
  assert.match(summary.textContent, /2 failed checks/);
  assert.match(summary.textContent, /Failed jobs are not loaded yet\. Find failed checks to expand their suites\./);
  assert.match(summary.textContent, /No explanations yet\./);
  const findButton = summary.querySelector("[data-action-id='find-failed-checks']");
  assert.ok(findButton, "the Find failed checks action must be present");
  assert.equal(findButton.disabled, false);
  assert.equal(summary.querySelector("[aria-label='Failed checks navigation']"), null, "no navigation until at least one failed check is discovered");
  assert.equal(unitToggle.getAttribute("aria-expanded"), "false");
  assert.equal(lintToggle.getAttribute("aria-expanded"), "false");
  assert.equal(managedToggle.getAttribute("aria-expanded"), "false");
  assert.equal(outsideToggle.getAttribute("aria-expanded"), "false");

  findButton.click();
  await settle();
  summary = document.querySelector("[data-ghpr-surface='github.pr.checks.summary']");
  assert.equal(new URLSearchParams(window.location.search).get("ghpr_check"), "first");
  assert.match(summary.textContent, /Loading checks from collapsed suites…/);
  assert.equal(unitToggle.getAttribute("aria-expanded"), "true", "the first collapsed suite must be expanded");
  assert.equal(lintToggle.getAttribute("aria-expanded"), "false", "discovery expands one suite at a time");
  assert.equal(unitTracker.count, 1);
  assert.equal(lintTracker.count, 0);
  assert.equal(managedToggle.getAttribute("aria-expanded"), "false", "ghpr-managed controls must never be clicked");
  assert.equal(outsideToggle.getAttribute("aria-expanded"), "false", "controls outside the discovered root must never be clicked");
  assert.equal(clicks.managed, 0);

  await new Promise((resolve) => window.setTimeout(resolve, 300));
  await settle();
  assert.equal(lintToggle.getAttribute("aria-expanded"), "true", "the second collapsed suite must be expanded next");
  assert.equal(unitTracker.count, 1, "an already-expanded suite must not be re-toggled");
  assert.equal(lintTracker.count, 1);

  await new Promise((resolve) => window.setTimeout(resolve, 300));
  await settle();
  summary = document.querySelector("[data-ghpr-surface='github.pr.checks.summary']");
  assert.match(summary.textContent, /2 failed checks · 2 available for navigation/);
  assert.equal(summary.querySelector("p[role='status']"), null, "loading status clears once discovery is bounded and complete");
  const jobButtons = [...summary.querySelectorAll(".ghpr-ci-summary-jobs button")];
  assert.deepEqual(jobButtons.map((button) => button.textContent), ["unit-test", "lint"]);

  // Re-requesting discovery after every suite is expanded must not re-click
  // any control or resurface the loading status.
  summary.querySelector("[data-action-id='find-failed-checks']").click();
  await settle();
  summary = document.querySelector("[data-ghpr-surface='github.pr.checks.summary']");
  assert.equal(unitTracker.count, 1);
  assert.equal(lintTracker.count, 1);
  assert.equal(summary.querySelector("p[role='status']"), null);

  jobButtons[0].click();
  await settle();
  let panel = document.querySelector("[data-ghpr-surface='github.pr.checks.job.insight']");
  assert.ok(panel, "selecting a discovered job opens the CI Insight panel");
  assert.equal(unitRow.nextElementSibling, panel);
  assert.match(panel.querySelector(".ghpr-item-navigator-count")?.textContent || "", /1 of 2 failed checks/);
  assert.equal(panel.querySelector("[data-action-id='previous-failed-check']")?.disabled, true);
  panel.querySelector("[data-action-id='next-failed-check']").click();
  panel = document.querySelector("[data-ghpr-surface='github.pr.checks.job.insight']");
  assert.equal(lintRow.nextElementSibling, panel, "navigation moves to a distinct discovered row");
  assert.match(panel.querySelector(".ghpr-item-navigator-count")?.textContent || "", /2 of 2 failed checks/);
  assert.equal(panel.querySelector("[data-action-id='next-failed-check']")?.disabled, true);

  const actionRequests = gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/actions");
  assert.equal(actionRequests.length, 0, "discovery and navigation must never invoke external GitHub/agent actions");

  app.stop();
  window.close();
});

test("v2: a native check_run_id anchor navigates via the original link instead of a fabricated workflow_job subject", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const { document } = window;
  for (const row of document.querySelectorAll("[data-testid='check-run-row']")) row.remove();

  const codeqlRow = document.createElement("div");
  codeqlRow.setAttribute("data-testid", "check-run-row");
  codeqlRow.setAttribute("data-check-name", "codeql");
  codeqlRow.innerHTML = "<span>codeql</span><strong>Failed</strong>";
  const link = document.createElement("a");
  link.setAttribute("href", "/acme/widgets/pull/42/checks?check_run_id=555");
  link.setAttribute("title", "View details");
  link.textContent = "Details";
  let linkClicked = false;
  link.addEventListener("click", (event) => {
    event.preventDefault();
    linkClicked = true;
  });
  codeqlRow.appendChild(link);
  document.querySelector("#checks_tab").appendChild(codeqlRow);

  const snapshot = makeSnapshot(pathname, {
    pull_request: { id: 42, repository: "acme/widgets", number: 42, title: "Fixture PR", ci_status: "FAILURE", check_failure_count: 1 },
    runs: []
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document, gm });
  await app.start();
  await settle();

  const summary = document.querySelector("[data-ghpr-surface='github.pr.checks.summary']");
  assert.ok(summary);
  const codeqlButton = [...summary.querySelectorAll(".ghpr-ci-summary-jobs button")]
    .find((button) => button.textContent === "codeql");
  assert.ok(codeqlButton, "the check_run_id-only row must still surface as a navigable failed check");
  assert.equal(codeqlRow.querySelector("[data-ghpr-surface='github.pr.checks.job.trailing']"), null,
    "a row without a resolvable workflow_job subject must never get fabricated Explain/Classify UI");

  codeqlButton.click();
  await settle();

  assert.equal(linkClicked, true, "selecting a check_run_id-only job must click the original native anchor");
  assert.equal(document.querySelector("[data-ghpr-surface='github.pr.checks.job.insight']"), null,
    "a check_run_id route must not open the CI Insight panel meant for exact workflow_job links");
  assert.equal(new URLSearchParams(window.location.search).get("ghpr_check"), "github:check-run:555");

  const resolveRequests = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/subjects/resolve")
    .map((request) => JSON.parse(request.data));
  assert.ok(
    resolveRequests.every((body) => !(body.type === "workflow_job" && String(body.workflow_job_id) === "555")),
    "the check_run_id must never be resolved as a fabricated workflow_job id"
  );
  const actionRequests = gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/actions");
  assert.equal(actionRequests.length, 0);

  app.stop();
  window.close();
});

test("v2: Actions Job page reuses the same subject-keyed CI Insight without a duplicate run", async () => {
  const pathname = "/acme/widgets/actions/runs/1001/job/2001";
  const window = await createWindow("actions-job.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    runs: [
      jobRun({
        skillID: "ci.failure.explain",
        runId: 1001,
        jobId: 2001,
        status: "completed",
        result: { payload: { why_it_failed: "Process completed with exit code 1.", relevant_evidence: [], suggested_action: "Inspect logs" } }
      })
    ]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const insight = window.document.querySelector("[data-ghpr-surface='github.actions.job.after-failure-summary']");
  assert.ok(insight, "existing Explain result must render on the Actions Job page without starting a new run");
  assert.match(insight.textContent, /Process completed with exit code 1/);
  assert.equal(insight.dataset.layout, "actions");
  const tabs = [...insight.querySelectorAll("[role='tab']")];
  assert.deepEqual(tabs.map((tab) => tab.textContent), [
    "Why it failed",
    "Flaky evidence",
    "History",
    "Suggested action"
  ]);
  const failureSummary = window.document.querySelector("[data-testid='failure-summary']");
  assert.equal(failureSummary.nextElementSibling, insight, "CI Insight must sit directly below the native failure summary");
  assert.equal(insight.nextElementSibling?.id, "logs", "native logs must remain directly after the injected insight");

  const runRequests = gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/actions");
  assert.equal(runRequests.length, 0, "no duplicate run should be started when a result already exists for this subject");


  const logsButton = [...insight.querySelectorAll("button")].find((b) => b.textContent === "View raw logs");
  logsButton.click();
  const logs = window.document.getElementById("logs");
  assert.equal(logs.hidden, false, "View raw logs must reveal the native Logs region in place");

  app.stop();
  window.close();
});
test("v2: a Checks run resolves the exact workflow job before invoking a Skill", async () => {
  const pathname = "/acme/widgets/pull/42/checks";
  const window = await createWindow("checks.html", pathname);
  const gm = new FakeGM({ snapshot: makeSnapshot(pathname) });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const row = [...window.document.querySelectorAll("[data-testid='check-run-row']")]
    .find((candidate) => candidate.dataset.checkName === "unit-test");
  [...row.querySelectorAll("button")].find((button) => button.textContent === "Explain").click();
  await settle();
  const insight = window.document.querySelector(
    "[data-ghpr-surface='github.pr.checks.job.insight']"
  );
  [...insight.querySelectorAll("button")]
    .find((button) => button.textContent === "Explain CI Failure")
    .click();
  const dialog = window.document.querySelector(
    "[data-ghpr-surface='github.pr.review-launch-dialog']"
  );
  assert.ok(dialog, "workflow-job explanation must reuse the coding agent selector");
  assert.equal(
    gm.requests.some((request) => new URL(request.url).pathname === "/api/v1/subjects/resolve"),
    false,
    "the exact workflow job must not resolve before runtime confirmation"
  );
  dialog.querySelector("[data-action-id='start-explain-failure']").click();
  await settle();

  const resolveRequest = gm.requests.find((request) =>
    new URL(request.url).pathname === "/api/v1/subjects/resolve"
  );
  assert.ok(resolveRequest, "the workflow job must be resolved before the run starts");
  const actionRequest = gm.requests.find((request) =>
    new URL(request.url).pathname === "/api/v1/actions"
  );
  const action = JSON.parse(actionRequest.data).action;
  assert.equal(action.subject.workflow_attempt, 2);
  assert.equal(action.subject.workflow_job_id, 2001);
  assert.equal(action.subject.head_sha, "a".repeat(40));

  [...insight.querySelectorAll("button")]
    .find((button) => button.textContent === "Explain CI Failure")
    .click();
  const retryDialog = window.document.querySelector(
    "[data-ghpr-surface='github.pr.review-launch-dialog']"
  );
  assert.ok(retryDialog, "a completed request must release the subject run guard");
  retryDialog.querySelector("[data-action-id='start-explain-failure']").click();
  await settle();
  assert.equal(
    gm.requests.filter((request) =>
      new URL(request.url).pathname === "/api/v1/subjects/resolve"
    ).length,
    2,
    "the exact workflow job can be explained again without reloading the page"
  );

  app.stop();
  window.close();
});

test("v2: Review PR confirms runtime and model before starting the exact revision", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    skills: [{
      id: "pr.review",
      display_name: "Review PR",
      agents: ["omp", "claude_code", "codex"],
      default_agent: "omp",
      is_runnable: true
    }],
    agent_runtime: [{
      agent: "codex",
      preference: { model: "gpt-5.6", reasoning_effort: "high" }
    }],
    agent_catalogs: [{
      agent: "codex",
      models: [{
        slug: "gpt-5.6",
        display_name: "GPT-5.6",
        default_effort: "medium",
        reasoning_efforts: [
          { effort: "medium", detail: "Balanced" },
          { effort: "high", detail: "Thorough" }
        ]
      }],
      reasoning_efforts: [
        { effort: "medium", detail: "Balanced" },
        { effort: "high", detail: "Thorough" }
      ]
    }]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();
  const healthSurfaces = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/surface-health")
    .map((request) => JSON.parse(request.data).surface);
  assert.ok(
    healthSurfaces.includes("github.pr.conversation.review-summary"),
    "Conversation must report its native surface health"
  );
  assert.ok(
    !healthSurfaces.includes("github.pr.checks.job.trailing"),
    "Conversation must not report the separate Checks-tab surface as missing"
  );

  const summary = window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.review-summary']"
  );
  const reviewButton = summary.querySelector("[aria-label='Configure review']");
  assert.ok(reviewButton, "Conversation must expose Configure review");
  reviewButton.click();

  const dialog = window.document.querySelector(
    "[data-ghpr-surface='github.pr.review-launch-dialog']"
  );
  assert.ok(dialog, "Review PR must open a confirmation dialog");
  assert.match(dialog.textContent, /Run review with ghpr/);
  assert.match(dialog.textContent, /Import an existing review/);
  assert.match(dialog.textContent, /aaaaaaa/);
  assert.match(dialog.textContent, /bbbbbbb/);

  const copyPrompt = dialog.querySelector("[data-action-id='copy-import-prompt']");
  copyPrompt.click();
  await settle();
  assert.match(gm.clipboard[0], /ghpr MCP tool `import_review`/);
  assert.match(gm.clipboard[0], new RegExp(`base_sha: ${"a".repeat(40)}`));
  assert.match(gm.clipboard[0], new RegExp(`head_sha: ${"b".repeat(40)}`));
  assert.match(gm.clipboard[0], /Do not submit a GitHub review or comment/);

  const runtime = dialog.querySelector("#ghpr-review-runtime");
  assert.equal(
    dialog.querySelector("#ghpr-review-model").tagName,
    "INPUT",
    "a runtime with no catalog must stay free-form"
  );
  runtime.value = "codex";
  runtime.dispatchEvent(new window.Event("change"));
  const codexModel = dialog.querySelector("#ghpr-review-model");
  assert.equal(codexModel.tagName, "SELECT", "a catalog-backed runtime must offer model selection");
  assert.deepEqual(
    [...codexModel.options].map((option) => option.value),
    ["", "gpt-5.6"]
  );
  assert.equal(codexModel.value, "gpt-5.6");
  assert.equal(dialog.querySelector("#ghpr-review-reasoning").value, "high");
  dialog.querySelector("[data-action-id='start-review']").click();
  await settle();

  const actionRequest = gm.requests.find((request) =>
    new URL(request.url).pathname === "/api/v1/actions"
  );
  const action = JSON.parse(actionRequest.data).action;
  assert.equal(action.skill_id, "pr.review");
  assert.equal(action.agent, "codex");
  assert.equal(action.model, "gpt-5.6");
  assert.equal(action.reasoning_effort, "high");
  assert.equal(action.subject.type, "pull_request_revision");
  assert.equal(action.subject.base_sha, "b".repeat(40));
  assert.equal(action.subject.head_sha, "a".repeat(40));
  assert.equal(
    window.document.querySelector("[data-ghpr-surface='github.pr.review-launch-dialog']"),
    null,
    "The dialog must close after the run is accepted"
  );

  app.stop();
  window.close();
});

test("v2: retrying an already-reviewed latest revision with no findings requires confirmation", async () => {
  const pathname = "/acme/widgets/pull/42";
  const latestHeadSHA = "a".repeat(40);
  const snapshot = makeSnapshot(pathname, {
    current_revision_subject: {
      type: "pull_request_revision",
      repository: "acme/widgets",
      pr_number: 42,
      base_sha: "b".repeat(40),
      head_sha: latestHeadSHA
    },
    runs: [{
      id: "run_review",
      skill_id: "pr.review",
      status: "completed",
      completed_at: "2026-08-24T00:01:00Z",
      subject: {
        type: "pull_request_revision",
        repository: "acme/widgets",
        pr_number: 42,
        base_sha: "b".repeat(40),
        head_sha: latestHeadSHA
      },
      result: {
        code_review: {
          overview_markdown: "No findings.",
          findings: []
        }
      }
    }]
  });
  const window = await createWindow("conversation.html", pathname);
  const confirmations = [];
  let confirmRetry = false;
  window.confirm = (message) => {
    confirmations.push(message);
    return confirmRetry;
  };
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const summary = window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.review-summary']"
  );
  const reviewButton = summary.querySelector("[aria-label='Configure review']");
  assert.ok(reviewButton, "a completed review must still expose Configure review");

  reviewButton.click();
  window.document
    .querySelector("[data-ghpr-surface='github.pr.review-launch-dialog'] [data-action-id='start-review']")
    .click();
  await settle();
  assert.deepEqual(confirmations, [
    "Revision aaaaaaa has already been reviewed. Review it again?"
  ]);
  assert.equal(
    gm.requests.some((request) => new URL(request.url).pathname === "/api/v1/actions"),
    false,
    "cancelling must not start another review"
  );

  confirmRetry = true;
  reviewButton.click();
  window.document
    .querySelector("[data-ghpr-surface='github.pr.review-launch-dialog'] [data-action-id='start-review']")
    .click();
  await settle();
  assert.equal(
    gm.requests.filter((request) => new URL(request.url).pathname === "/api/v1/actions").length,
    1,
    "confirming must start exactly one retry"
  );

  app.stop();
  window.close();
});

test("v2: Review Summary preserves userscript update detection", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({
    snapshot: makeSnapshot(pathname),
    latestVersion: "2.1.0"
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const summary = window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.review-summary']"
  );
  const update = [...summary.querySelectorAll("button")]
    .find((button) => button.textContent === "Update ghpr userscript");
  assert.ok(update, "a newer Bridge-served userscript must be actionable on the v2 surface");
  update.click();
  assert.deepEqual(gm.opened, ["http://127.0.0.1:48120/install/ghpr.user.js"]);

  app.stop();
  window.close();
});

function persistedReviewFinding(overrides = {}) {
  const subject = {
    type: "diff_line",
    repository: "acme/widgets",
    pr_number: 42,
    base_sha: "a".repeat(40),
    head_sha: "b".repeat(40),
    blob_sha: "c".repeat(40),
    file_path: "src/index.ts",
    side: "right",
    start_line: 8,
    end_line: 10,
    hunk_fingerprint: "hunk-fingerprint",
    quoted_code: "- return legacy()\n+ return next()"
  };
  return {
    id: "finding_1",
    subject_key: "github:diff-line:fixture",
    kind: "review_finding",
    severity: "warning",
    title: "Prefer next() over legacy()",
    summary: "The legacy helper can publish a stale cache entry.",
    details: "The legacy path can return stale state.",
    confidence: 0.7,
    lifecycle: "exact",
    created_at: "2026-08-24T00:01:00Z",
    fingerprint: "finding-fingerprint",
    ...overrides,
    subject: { ...subject, ...(overrides.subject || {}) }
  };
}

test("v2: Conversation Review Summary renders inline without a native comment or local detail page", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    runs: [{
      id: "run_review",
      skill_id: "pr.review",
      status: "completed",
      completed_at: "2026-08-24T00:01:00Z",
      result: {
        code_review: {
          head_sha: "b".repeat(40),
          overview_markdown: "One finding.",
          findings: [{
            id: "finding_1",
            file: "src/index.ts",
            line: 10,
            side: "addition",
            severity: "warning",
            confidence: 0.7,
            body: "Prefer next() over legacy()"
          }]
        }
      }
    }],
    findings: [persistedReviewFinding()]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const summary = window.document.querySelector("[data-ghpr-surface='github.pr.conversation.review-summary']");
  assert.ok(summary, "Conversation Review Summary surface must mount");
  assert.match(summary.textContent, /Reviewers/);
  assert.match(summary.textContent, /Review details/);
  assert.equal(
    [...summary.querySelectorAll("button")].some((button) => /Dismiss|Open in editor/.test(button.textContent)),
    false,
    "summary findings must stay navigational and must not expose privileged actions"
  );
  const viewDiffContext = summary.querySelector("[data-action-id='view-diff-context']");
  assert.ok(viewDiffContext, "the completed review must link each finding to its Files changed context");
  viewDiffContext.click();
  assert.equal(window.location.pathname, "/acme/widgets/pull/42/changes");
  assert.equal(new URLSearchParams(window.location.search).get("ghpr_finding"), "finding_1");
  assert.equal(new URLSearchParams(window.location.search).get("path"), "src/index.ts");
  assert.equal(new URLSearchParams(window.location.search).get("line"), "10");
  assert.equal(summary.parentElement?.id, "partial-discussion-sidebar", "review belongs in the native sidebar");
  assert.ok(window.document.querySelector(".sidebar-reviewers"), "native reviewers remain untouched");

  const mergeBox = window.document.querySelector("[data-testid='merge-box']");
  assert.ok(mergeBox, "native merge box must remain untouched");
  assert.equal(mergeBox.querySelector("[data-ghpr-surface]"), null);

  app.stop();
  window.close();
});

test("v2: Review Summary copies a single finding and the whole review", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    runs: [{
      skill_id: "pr.review",
      status: "completed",
      completed_at: "2026-08-24T00:01:00Z",
      result: { code_review: { head_sha: "b".repeat(40), overview_markdown: "Two findings.", findings: [{ id: "finding_1" }, { id: "finding_2" }] } }
    }],
    findings: [
      persistedReviewFinding(),
      persistedReviewFinding({
        id: "finding_2",
        title: "Guard the null branch",
        summary: "The cache read can return null.",
        details: "A null entry reaches the caller unchecked.",
        subject: { file_path: "src/cache.ts", start_line: 20, end_line: 20 }
      })
    ]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const summary = window.document.querySelector("[data-ghpr-surface='github.pr.conversation.review-summary']");
  const copyButtons = [...summary.querySelectorAll("[data-action-id='copy-finding']")];
  assert.equal(copyButtons.length, 2, "selected review findings are the only copyable findings");
  copyButtons[1].click();
  await settle();
  assert.match(gm.clipboard[0], /^\[Warning\] Guard the null branch$/m);
  assert.match(gm.clipboard[0], /src\/cache\.ts · L20 · reviewed bbbbbbb/);
  assert.match(gm.clipboard[0], /A null entry reaches the caller unchecked\./);
  assert.equal(
    /Prefer next\(\)/.test(gm.clipboard[0]),
    false,
    "copying one item must not drag in its neighbours"
  );
  assert.equal(copyButtons[1].textContent, "Copied");
  assert.equal(
    window.location.pathname,
    pathname,
    "copying from a collapsed item must not also open its diff context"
  );

  const copyAll = summary.querySelector("[data-action-id='copy-all']");
  assert.ok(copyAll, "the summary must offer a copy-all control");
  copyAll.click();
  await settle();
  assert.equal(gm.clipboard.length, 2);
  const everything = gm.clipboard[1];
  assert.match(everything, /^ghpr Review Summary$/m);
  assert.match(everything, /^2 findings · 2 files$/m);
  assert.match(everything, /Guard the null branch/);

  app.stop();
  window.close();
});

test("v2: Conversation keeps actions in Annotations and the review sidebar without a duplicate operation card", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = await findingsFixtureSnapshot(pathname);
  snapshot.skills = [{
    id: "pr.review",
    display_name: "Review PR",
    agents: ["codex"],
    default_agent: "codex",
    is_runnable: true
  }, {
    id: "team.review.release-risk",
    version: "1.0.0",
    display_name: "Check release risk",
    summary: "Review release risk for this pull request.",
    targets: ["pull_request"],
    agents: ["codex"],
    default_agent: "codex",
    is_built_in: false,
    has_browser_companion: false,
    is_runnable: true
  }, {
    id: "ci.failure.explain",
    display_name: "Explain CI Failure",
    agents: ["codex"],
    default_agent: "codex",
    is_runnable: true
  }];
  snapshot.agent_runtime = [{
    agent: "codex",
    preference: { model: "gpt-5.6", reasoning_effort: "high" }
  }];
  snapshot.agent_catalogs = [{
    agent: "codex",
    models: [{
      slug: "gpt-5.6",
      display_name: "GPT-5.6",
      default_effort: "medium",
      reasoning_efforts: [
        { effort: "medium", detail: "Balanced" },
        { effort: "high", detail: "Thorough" }
      ]
    }],
    reasoning_efforts: [
      { effort: "medium", detail: "Balanced" },
      { effort: "high", detail: "Thorough" }
    ]
  }];
  snapshot.pull_request = {
    ...snapshot.pull_request,
    ci_status: "PENDING",
    check_failure_count: 1,
    check_pending_count: 2,
    ci_is_running: true
  };
  snapshot.runs = [
    ...(snapshot.runs || []),
    {
      id: "run-explain-old",
      skill_id: "ci.failure.explain",
      subject: { type: "legacy_page", page: snapshot.page },
      status: "completed",
      completed_at: "2026-08-24T00:01:00Z",
      result: {
        payload: {
          why_it_failed: "An obsolete packaging failure.",
          relevant_evidence: []
        }
      }
    },
    {
      id: "run-explain-current",
      skill_id: "ci.failure.explain",
      subject: { type: "legacy_page", page: snapshot.page },
      status: "completed",
      completed_at: "2026-08-24T00:03:00Z",
      result: {
        payload: {
          why_it_failed: "The lint step rejected an invalid import.",
          relevant_evidence: ["eslint exited with code 1"],
          _ghpr_job: {
            repository: "acme/widgets",
            workflow_run_id: "1001",
            workflow_job_id: "2002",
            workflow_name: "lint"
          }
        }
      }
    }
  ];
  const gm = new FakeGM({ snapshot });
  window.confirm = () => {
    throw new Error("Failed-check actions must not use browser confirm dialogs.");
  };
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  assert.equal(
    window.document.querySelector("#ghpr-operation-card"),
    null,
    "a healthy Conversation page must not mount a second ghpr card"
  );
  assert.equal(
    window.document.querySelectorAll(
      "[data-ghpr-surface='github.pr.conversation.review-summary']"
    ).length,
    1
  );
  assert.equal(
    window.document.querySelector("[data-action-id='review-pr']"),
    null,
    "review requests must use the native-style reviewer controls"
  );
  assert.equal(window.document.querySelector("#ghpr-github-root"), null);
  assert.equal(window.document.querySelector("#ghpr-header-entry"), null);

  const reviewSummary = window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.review-summary']"
  );
  assert.ok(reviewSummary.querySelector("[aria-label='Configure review']"));
  const skillMenu = reviewSummary.querySelector(".ghpr-operation-skill-menu");
  assert.ok(skillMenu, "custom skills must remain available from the review toolbar");
  const customSkill = skillMenu.querySelector(
    "[data-action-id='run-skill-team.review.release-risk']"
  );
  assert.ok(customSkill);
  customSkill.click();
  await settle();
  const customSkillRequest = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map((request) => JSON.parse(request.data))
    .find((body) => body.action?.skill_id === "team.review.release-risk");
  assert.equal(customSkillRequest?.action?.subject?.type, "pull_request_revision");
  assert.equal(customSkillRequest?.action?.subject?.head_sha, "a".repeat(40));

  const annotations = window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.annotations']"
  );
  assert.match(annotations.textContent, /The lint step rejected an invalid import/);
  assert.doesNotMatch(annotations.textContent, /obsolete packaging failure/);
  const viewFailedChecks = annotations.querySelector(
    "[data-action-id='view-failed-checks']"
  );
  assert.ok(viewFailedChecks, "failed checks must be reachable from Annotations");
  const explain = annotations.querySelector("[data-action-id='explain-ci-failure']");
  const rerun = annotations.querySelector("[data-action-id='rerun-failed-ci']");
  assert.ok(explain);
  assert.ok(rerun);
  explain.click();
  assert.equal(
    gm.requests.some((request) =>
      new URL(request.url).pathname === "/api/v1/actions" &&
      JSON.parse(request.data).action?.skill_id === "ci.failure.explain"
    ),
    false,
    "opening the runtime picker must not start the explanation"
  );
  const explainDialog = window.document.querySelector(
    "[data-ghpr-surface='github.pr.review-launch-dialog']"
  );
  assert.equal(explainDialog.querySelector("#ghpr-review-runtime").value, "codex");
  assert.equal(explainDialog.querySelector("#ghpr-review-model").value, "gpt-5.6");
  assert.equal(explainDialog.querySelector("#ghpr-review-reasoning").value, "high");
  assert.equal(
    explainDialog.querySelector("[data-action-id='copy-import-prompt']"),
    null,
    "failure explanation does not expose the external review import workflow"
  );
  explainDialog.querySelector("[data-action-id='start-explain-failure']").click();
  await settle();
  const explainRequest = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map((request) => JSON.parse(request.data))
    .find((body) => body.action?.skill_id === "ci.failure.explain");
  assert.equal(explainRequest?.action?.kind, "run_skill");
  assert.equal(explainRequest?.action?.agent, "codex");
  assert.equal(explainRequest?.action?.model, "gpt-5.6");
  assert.equal(explainRequest?.action?.reasoning_effort, "high");
  assert.equal(explainRequest?.page?.key, snapshot.page.key);

  window.document
    .querySelector("[data-action-id='rerun-failed-ci']")
    .click();
  const rerunDialog = window.document.querySelector(
    "[data-ghpr-surface='github.pr.review-launch-dialog']"
  );
  assert.ok(rerunDialog.querySelector("[data-action-id='explain-before-rerun']"));
  assert.ok(rerunDialog.querySelector("[data-action-id='rerun-anyway']"));
  rerunDialog.querySelector("[data-action-id='rerun-anyway']").click();
  await settle();
  assert.equal(
    gm.requests
      .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
      .map((request) => JSON.parse(request.data))
      .some((body) => body.action?.kind === "rerun_failed_jobs"),
    true
  );

  const reviewDetails = reviewSummary.querySelector(
    ".ghpr-review-summary-details > button[aria-expanded]"
  );
  assert.ok(reviewDetails, "the selected review must expose its navigation actions");
  reviewDetails.click();
  const viewFiles = reviewSummary.querySelector("[data-action-id='view-files']");
  assert.ok(viewFiles, "Review details must navigate to the selected finding");

  viewFailedChecks.click();
  assert.equal(window.location.pathname, "/acme/widgets/pull/42/checks");
  assert.equal(new URLSearchParams(window.location.search).get("ghpr_check"), "first");

  viewFiles.click();
  assert.equal(window.location.pathname, "/acme/widgets/pull/42/changes");
  assert.equal(
    new URLSearchParams(window.location.search).get("ghpr_finding"),
    "finding_1"
  );

  app.stop();
  window.close();
});

test("v2: Annotations keeps failed-CI rerun available without review permission", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    pull_request: {
      id: 42,
      repository: "acme/widgets",
      number: 42,
      title: "Fixture PR",
      ci_status: "FAILURE",
      check_failure_count: 2
    }
  });
  window.confirm = () => {
    throw new Error("The rerun modal must replace browser confirm dialogs.");
  };
  const gm = new FakeGM({
    snapshot,
    clientScopes: CLIENT.requested_scopes.filter((scope) => scope !== "skill:run")
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  assert.equal(window.document.querySelector("#ghpr-operation-card"), null);
  const annotations = window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.annotations']"
  );
  assert.match(annotations.textContent, /2 failed checks/);
  const rerun = annotations.querySelector("[data-action-id='rerun-failed-ci']");
  assert.ok(rerun, "GitHub failed jobs can be rerun without skill:run");
  assert.equal(
    window.document.querySelector("[data-ghpr-surface='github.pr.conversation.checks.actions']"),
    null,
    "failed-check actions belong in Annotations"
  );

  rerun.click();
  await settle();
  const rerunDialog = window.document.querySelector(
    "[data-ghpr-surface='github.pr.review-launch-dialog']"
  );
  assert.ok(rerunDialog);
  assert.equal(
    rerunDialog.querySelector("[data-action-id='explain-before-rerun']"),
    null,
    "Explain is unavailable without skill:run"
  );
  rerunDialog.querySelector("[data-action-id='rerun-anyway']").click();
  await settle();
  const rerunRequest = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map((request) => JSON.parse(request.data))
    .find((body) => body.action?.kind === "rerun_failed_jobs");
  assert.equal(rerunRequest?.page?.key, snapshot.page.key);
  assert.equal(rerunRequest?.confirmed, true);

  app.stop();
  window.close();
});

test("v2: a passing PR exposes no failed-check actions", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({ snapshot: makeSnapshot(pathname) });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  assert.ok(
    window.document.querySelector(
      "[data-ghpr-surface='github.pr.conversation.review-summary']"
    )
  );
  assert.equal(
    window.document.querySelector("[data-action-id='view-failed-checks']"),
    null
  );
  assert.equal(
    window.document.querySelector("[data-action-id='explain-ci-failure']"),
    null
  );
  assert.equal(
    window.document.querySelector("[data-action-id='rerun-failed-ci']"),
    null
  );

  app.stop();
  window.close();
});

test("v2: failed-check actions require an actual failed check result", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    pull_request: {
      id: 42,
      repository: "acme/widgets",
      number: 42,
      title: "Fixture PR",
      ci_status: "FAILURE",
      check_failure_count: 0
    }
  });
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ snapshot })
  });
  await app.start();
  await settle();

  assert.equal(window.document.querySelector("#ghpr-operation-card"), null);
  assert.equal(
    window.document.querySelector("[data-action-id='view-failed-checks']"),
    null
  );
  assert.equal(
    window.document.querySelector("[data-action-id='explain-ci-failure']"),
    null
  );
  assert.equal(
    window.document.querySelector("[data-action-id='rerun-failed-ci']"),
    null
  );

  app.stop();
  window.close();
});


test("v2: failed-check actions reflect backend run and permission state", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    pull_request: {
      id: 42,
      repository: "acme/widgets",
      number: 42,
      title: "Fixture PR",
      ci_status: "PENDING",
      check_failure_count: 2
    },
    runs: [{
      id: "run-explain-active",
      skill_id: "ci.failure.explain",
      status: "running",
      started_at: "2026-08-24T00:01:00Z"
    }]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const annotations = () => window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.annotations']"
  );
  const explainAction = () => annotations()?.querySelector(
    "[data-action-id='explain-ci-failure']"
  );
  assert.equal(window.document.querySelector("#ghpr-operation-card"), null);
  assert.ok(annotations()?.querySelector("[data-action-id='view-failed-checks']"));
  assert.equal(
    explainAction()?.textContent,
    "Explaining…"
  );
  assert.equal(explainAction()?.disabled, true);

  gm.snapshot = {
    ...snapshot,
    runs: [{
      id: "run-explain-completed",
      skill_id: "ci.failure.explain",
      status: "completed",
      started_at: "2026-08-24T00:01:00Z",
      completed_at: "2026-08-24T00:02:00Z"
    }]
  };
  await app.refresh();
  assert.equal(
    explainAction()?.textContent,
    "Explain again"
  );

  gm.snapshot = {
    ...snapshot,
    runs: [{
      id: "run-explain-failed",
      skill_id: "ci.failure.explain",
      status: "failed",
      started_at: "2026-08-24T00:03:00Z",
      completed_at: "2026-08-24T00:04:00Z"
    }]
  };
  await app.refresh();
  assert.equal(
    explainAction()?.textContent,
    "Retry explain"
  );

  app.stop();
  window.close();

  const restrictedWindow = await createWindow("conversation.html", pathname);
  const restrictedApp = createGhprApp({
    window: restrictedWindow,
    document: restrictedWindow.document,
    gm: new FakeGM({
      snapshot,
      clientScopes: CLIENT.requested_scopes.filter((scope) => scope !== "skill:run")
    })
  });
  await restrictedApp.start();
  await settle();
  const restrictedSummary = restrictedWindow.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.annotations']"
  );
  assert.equal(restrictedWindow.document.querySelector("#ghpr-operation-card"), null);
  assert.equal(restrictedSummary.querySelector("[data-action-id='explain-ci-failure']"), null);
  assert.ok(restrictedSummary.querySelector("[data-action-id='rerun-failed-ci']"));
  assert.ok(restrictedSummary.querySelector("[data-action-id='view-failed-checks']"));
  restrictedApp.stop();
  restrictedWindow.close();
});

test("v2: the review sidebar exposes active progress without a duplicate run action", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    pull_request: {
      id: 42,
      repository: "acme/widgets",
      number: 42,
      title: "Fixture PR",
      ci_status: "SUCCESS"
    },
    skills: [{
      id: "pr.review",
      display_name: "Review PR",
      agents: ["claude_code"],
      default_agent: "claude_code",
      is_runnable: true
    }],
    runs: [{
      id: "run_review_active",
      skill_id: "pr.review",
      agent: "claude_code",
      status: "running",
      started_at: "2026-08-24T00:01:00Z",
      progress_message: "Receiving Agent output",
      log_entries: [
        {
          timestamp: "2026-08-24T00:01:00Z",
          kind: "running",
          message: "Skill: Review PR (pr.review)",
          stream: "skill_input"
        },
        {
          timestamp: "2026-08-24T00:01:01Z",
          kind: "running",
          message: "Target: pull_request_revision · acme/widgets#42 @ aaaaaaa",
          stream: "skill_input"
        },
        {
          timestamp: "2026-08-24T00:01:02Z",
          kind: "running",
          message: "Diff: 1 file · 12 lines · 480 bytes",
          stream: "skill_input"
        },
        {
          timestamp: "2026-08-24T00:01:03Z",
          kind: "running",
          message: "Inspecting changed cache write",
          stream: "agent_output"
        },
        {
          timestamp: "2026-08-24T00:01:04Z",
          kind: "running",
          message: "Finding: possible lost update",
          stream: "agent_output"
        }
      ],
      result: null
    }]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  assert.equal(window.document.querySelector("#ghpr-operation-card"), null);
  const summary = window.document.querySelector(
    "[data-ghpr-surface='github.pr.conversation.review-summary']"
  );
  assert.match(summary.textContent, /Coding agent · Claude Code/);
  assert.equal(summary.querySelector("[data-action-id='review-pr']"), null);
  const request = summary.querySelector("[data-action-id='request-review-claude_code']");
  assert.ok(request);
  assert.equal(request.disabled, true, "an active review must disable duplicate requests");
  const progress = summary.querySelector(".ghpr-operation-progress");
  assert.ok(progress, "an active review must expose its execution log in the sidebar");
  assert.equal(progress.open, false, "the review log must default to collapsed");
  assert.deepEqual(
    [...progress.querySelectorAll(".ghpr-operation-progress-line code")].map((line) => line.textContent),
    [
      "Skill: Review PR (pr.review)",
      "Target: pull_request_revision · acme/widgets#42 @ aaaaaaa",
      "Diff: 1 file · 12 lines · 480 bytes",
      "Inspecting changed cache write",
      "Finding: possible lost update"
    ]
  );
  const steps = [...progress.querySelectorAll(".ghpr-operation-progress-step")];
  assert.deepEqual(
    steps.map((step) =>
      step.querySelector(".ghpr-operation-progress-step-marker")?.nextElementSibling?.textContent
    ),
    ["Executing Skill", "Receiving Agent output"]
  );
  assert.deepEqual(steps.map((step) => step.open), [false, true]);
  assert.equal(progress.querySelector(".ghpr-operation-progress-log")?.getAttribute("role"), "log");
  progress.querySelector(":scope > summary").click();
  assert.equal(progress.open, true);
  app.render();
  assert.equal(
    window.document
      .querySelector("[data-ghpr-surface='github.pr.conversation.review-summary']")
      ?.querySelector(".ghpr-operation-progress")
      ?.open,
    true,
    "refreshing the active run must preserve the user's expansion choice"
  );

  app.stop();
  window.close();
});

test("v2: compact operation card remains visible when the local app is not paired", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({ snapshot: makeSnapshot(pathname) });
  gm.storage.delete("ghpr.bridge.token");
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const card = window.document.querySelector("#ghpr-operation-card");
  assert.ok(card, "v2 must keep a visible connection path on the PR page");
  assert.match(card.textContent, /Not connected/);
  assert.equal(
    card.querySelector("[data-action-id='connect']")?.textContent,
    "Connect ghpr"
  );

  app.stop();
  window.close();
});

test("v2: a failed page snapshot stays visible and can be retried in place", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({
    snapshot: makeSnapshot(pathname),
    pageFailure: "Browser Bridge timed out."
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const pageRequest = gm.requests.find(
    (request) => new URL(request.url).pathname === "/api/v1/page"
  );
  assert.equal(
    pageRequest?.timeout,
    20000,
    "the page snapshot must outlast a slow revision resolve"
  );
  assert.equal(
    gm.requests.find(
      (request) => new URL(request.url).pathname === "/.well-known/ghpr-browser-bridge"
    )?.timeout,
    4000,
    "discovery must keep failing fast across the port range"
  );

  let card = window.document.querySelector("#ghpr-operation-card .ghpr-operation-card");
  assert.ok(card, "a failed snapshot must still mount a visible card");
  assert.equal(card.dataset.state, "attention");
  assert.match(card.textContent, /Unavailable/);
  assert.match(card.textContent, /Browser Bridge timed out/);

  gm.pageFailure = null;
  card.querySelector("[data-action-id='retry']").click();
  await settle();

  assert.equal(
    window.document.querySelector("#ghpr-operation-card"),
    null,
    "successful recovery must replace the temporary recovery card with the sidebar"
  );
  assert.ok(
    window.document.querySelector(
      "[data-ghpr-surface='github.pr.conversation.review-summary']"
    )
  );

  app.stop();
  window.close();
});

test("v2: a render crash reports itself and keeps polling alive", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const gm = new FakeGM({ snapshot: makeSnapshot(pathname) });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const errors = [];
  window.console.error = (...args) => errors.push(args.map(String).join(" "));
  let scheduled = 0;
  const realSchedule = app.scheduleNextRefresh.bind(app);
  app.scheduleNextRefresh = () => {
    scheduled += 1;
    if (scheduled === 1) throw new Error("finally exploded");
    realSchedule();
  };

  await app.refreshSafely();

  assert.match(errors.join("\n"), /\[ghpr\] refresh failed:.*finally exploded/);
  assert.equal(app.refreshing, false, "a crash must not leave refresh latched");
  assert.equal(scheduled, 2, "polling must be rescheduled after the crash");

  app.stop();
  window.close();
});

async function findingsFixtureSnapshot(pathname) {
  return makeSnapshot(pathname, {
    runs: [{
      id: "run_review",
      skill_id: "pr.review",
      agent: "codex",
      status: "completed",
      completed_at: "2026-08-24T00:01:00Z",
      result: {
        code_review: {
          head_sha: "b".repeat(40),
          overview_markdown: "One finding.",
          findings: [{
            id: "finding_1",
            file: "src/index.ts",
            line: 10,
            side: "addition",
            severity: "warning",
            confidence: 0.7,
            body: "Prefer next() over legacy()",
            quoted_code: "- return legacy()\n+ return next()",
            details: {
              why: "The legacy path can return stale state.",
              suggestion: "Use the current helper."
            }
          }]
        }
      }
    }],
    findings: [persistedReviewFinding()]
  });
}

test("v2: Files changed (unified) marks the exact added line and not the deleted counterpart", async () => {
  const pathname = "/acme/widgets/pull/42/files";
  const window = await createWindow("files-unified.html", pathname);
  const snapshot = await findingsFixtureSnapshot(pathname);
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const toolbar = window.document.querySelector("[data-testid='files-toolbar']");
  assert.equal(
    toolbar.querySelector("[data-ghpr-files-review-menu]"),
    null,
    "ghpr must not insert controls into the native Files toolbar"
  );
  const operationCard = window.document.querySelector("#ghpr-operation-card");
  operationCard.querySelector("[data-action-id='toggle-operation-card']").click();
  const reviewButton = operationCard.querySelector("[data-action-id='review-pr']");
  assert.equal(reviewButton?.textContent, "Review latest");
  reviewButton.click();
  window.document
    .querySelector("[data-ghpr-surface='github.pr.review-launch-dialog'] [data-action-id='start-review']")
    .click();
  await settle();
  const reviewAction = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map((request) => JSON.parse(request.data).action)
    .find((action) => action.skill_id === "pr.review");
  assert.equal(reviewAction.subject.type, "pull_request_revision");
  assert.equal(reviewAction.subject.head_sha, "a".repeat(40));

  const additionCell = window.document.querySelector(".blob-code-addition");
  const deletionCell = window.document.querySelector(".blob-code-deletion");
  assert.ok(additionCell.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']"));
  assert.equal(deletionCell.querySelector("[data-ghpr-surface]"), null);
  const marker = additionCell.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']");
  assert.equal(marker.getAttribute("data-inline"), "true", "the line decoration must render as an inline finding card");
  assert.equal(marker.getAttribute("data-expanded"), "false", "details stay collapsed until the card is opened");
  assert.match(marker.textContent, /Prefer next\(\) over legacy\(\)/, "the finding must be readable without opening it");
  assert.match(marker.textContent, /The legacy helper can publish a stale cache entry/, "the card must preview the summary");
  assert.match(marker.textContent, /L8-L10/, "the card must state the finding's line range");
  assert.match(marker.textContent, /bbbbbbb/, "the card must name the reviewed commit");
  assert.equal(marker.querySelector(".ghpr-diff-snippet"), null, "the inline card must not repeat the diff it sits on");
  marker.click();
  await settle();
  const sourceRow = additionCell.closest("tr");
  const detailRow = sourceRow.nextElementSibling;
  assert.ok(detailRow?.classList.contains("ghpr-inline-finding-row"), "the selected finding must expand directly under its diff row");
  assert.match(detailRow.textContent, /Prefer next\(\) over legacy\(\)/);
  assert.match(detailRow.textContent, /The legacy path can return stale state/);
  assert.match(detailRow.textContent, /reviewed bbbbbbb/, "the expanded finding must name the commit it was reviewed against");
  assert.ok(detailRow.querySelector(".ghpr-diff-snippet-line[data-kind='removed']"));
  assert.ok(detailRow.querySelector(".ghpr-diff-snippet-line[data-kind='added']"));
  assert.equal(
    additionCell
      .querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']")
      .getAttribute("data-expanded"),
    "true",
    "the opened card must report its expanded state"
  );

  app.stop();
  window.close();
});

test("v2: Files changed (split) marks the correct side's cell for the same line number", async () => {
  const pathname = "/acme/widgets/pull/42/files";
  const window = await createWindow("files-split.html", pathname);
  const snapshot = await findingsFixtureSnapshot(pathname);
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const additionCell = window.document.querySelector(".blob-code-addition");
  const deletionCell = window.document.querySelector(".blob-code-deletion");
  assert.ok(additionCell.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']"));
  assert.equal(deletionCell.querySelector("[data-ghpr-surface]"), null);

  app.stop();
  window.close();
});

test("v2: GitHub changes route opens the first finding and navigates between findings in-page", async (t) => {
  const pathname = "/acme/widgets/pull/42/changes?ghpr_finding=finding_1";
  const window = await createWindow("files-changes-react.html", pathname);
  const snapshot = await findingsFixtureSnapshot(pathname);
  snapshot.findings.push(persistedReviewFinding({
    id: "finding_2",
    subject_key: "github:diff-line:fixture-2",
    title: "Preserve the current cache key",
    summary: "Preserve the current cache key",
    fingerprint: "finding-fingerprint-2"
  }));
  const commentButton = window.document.createElement("button");
  commentButton.setAttribute("aria-expanded", "false");
  commentButton.setAttribute("aria-label", "Add comment on file");
  let commentPopupCount = 0;
  commentButton.addEventListener("click", () => {
    commentPopupCount += 1;
  });
  window.document
    .querySelector("#diff-reactfixture [data-diff-header-wrapper]")
    .append(commentButton);
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  t.after(() => {
    app.stop();
    window.close();
  });
  await app.start();
  await settle();
  const operationCardHost = window.document.querySelector("#ghpr-operation-card");
  const operationCard = operationCardHost?.querySelector(".ghpr-operation-card");
  const submitReview = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent.includes("Submit review"));
  const submitReviewContainer = submitReview?.parentElement;
  assert.ok(operationCardHost?.classList.contains("ghpr-operation-card-floating"));
  assert.ok(operationCardHost?.classList.contains("ghpr-operation-card-collapsed"));
  assert.equal(operationCardHost?.parentElement, window.document.body);
  assert.equal(operationCard?.dataset.collapsed, "true");
  assert.equal(operationCard?.querySelector(".ghpr-operation-card-body")?.hidden, true);
  assert.equal(
    operationCard?.querySelector("[data-action-id='toggle-operation-card']")?.getAttribute("aria-label"),
    "Expand ghpr card"
  );
  const submitReviewControlCount = submitReviewContainer?.children.length;
  assert.equal(submitReviewControlCount, 2, "the native Files toolbar must keep only its two controls");
  assert.equal(submitReviewContainer?.contains(operationCardHost), false);

  operationCard.querySelector("[data-action-id='toggle-operation-card']").click();
  assert.equal(operationCardHost.querySelector(".ghpr-operation-card")?.dataset.collapsed, "false");
  assert.equal(
    operationCardHost.querySelector(".ghpr-operation-card-body")?.hidden,
    false
  );
  assert.equal(submitReviewContainer?.children.length, 2);
  await app.refresh();
  assert.equal(
    operationCardHost.querySelector(".ghpr-operation-card")?.dataset.collapsed,
    "false",
    "the user's expanded state must survive snapshot refreshes"
  );
  const fileTreeBadge = window.document.querySelector(
    "#src\\/index\\.ts [data-ghpr-file-tree-badge]"
  );
  assert.equal(fileTreeBadge?.textContent, "2");
  assert.equal(fileTreeBadge?.tagName, "BUTTON");
  assert.equal(
    fileTreeBadge?.getAttribute("aria-label"),
    "Open first of 2 ghpr findings in src/index.ts"
  );
  assert.equal(
    window.document.querySelector("#src\\/index\\.ts [data-testid='native-comments-count']")?.textContent,
    "3"
  );
  assert.equal(
    window.document.querySelector("#src\\/other\\.ts [data-ghpr-file-tree-badge]"),
    null
  );


  const targetRegion = window.document.querySelector("#diff-reactfixture");
  const additionCell = targetRegion.querySelector(
    "td[data-line-anchor][data-diff-side='right'][data-line-number='10']"
  );
  const deletionCell = targetRegion.querySelector(
    "td[data-line-anchor][data-diff-side='left'][data-line-number='10']"
  );
  const sameLineInOtherFile = window.document.querySelector(
    "#diff-reactother td[data-line-anchor][data-diff-side='right'][data-line-number='10']"
  );
  assert.ok(additionCell.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']"));
  assert.equal(deletionCell.querySelector("[data-ghpr-surface]"), null);
  assert.equal(sameLineInOtherFile.querySelector("[data-ghpr-surface]"), null);

  let panel = window.document.querySelector("[data-testid='ghpr-inline-finding-panel']");
  assert.match(panel?.textContent || "", /Prefer next\(\) over legacy\(\)/);
  assert.match(panel?.querySelector(".ghpr-item-navigator-count")?.textContent || "", /1 of 2 findings/);
  panel.querySelector("[data-action-id='next-finding']").click();
  await settle();
  assert.equal(commentPopupCount, 0, "finding navigation must not activate the file comment button");

  panel = window.document.querySelector("[data-testid='ghpr-inline-finding-panel']");
  assert.match(panel?.textContent || "", /Preserve the current cache key/);
  assert.match(panel?.querySelector(".ghpr-item-navigator-count")?.textContent || "", /2 of 2 findings/);
  assert.equal(new URLSearchParams(window.location.search).get("ghpr_finding"), "finding_2");
  assert.equal(panel.querySelector("[data-action-id='next-finding']")?.disabled, true);
  fileTreeBadge.click();
  await settle();
  panel = window.document.querySelector("[data-testid='ghpr-inline-finding-panel']");
  assert.match(panel?.textContent || "", /Prefer next\(\) over legacy\(\)/);
  assert.equal(new URLSearchParams(window.location.search).get("ghpr_finding"), "finding_1");

  assert.match(
    panel?.querySelector(".ghpr-item-navigator-count")?.textContent || "",
    /1 of 2 findings/
  );

});

test("v2: finding drawer never calls GM.openInTab", async () => {
  const pathname = "/acme/widgets/pull/42/files";
  const window = await createWindow("files-unified.html", pathname);

  const snapshot = await findingsFixtureSnapshot(pathname);
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const marker = window.document.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']");
  marker.click();
  await settle();

  assert.deepEqual(gm.opened, [], "opening finding detail must never call GM.openInTab");

  app.stop();
  window.close();
});

test("v2: a finding without a diff row renders as a file-level card above the diff", async () => {
  const pathname = "/acme/widgets/pull/42/files?ghpr_finding=finding_1";
  const window = await createWindow("files-unified.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    findings: [persistedReviewFinding({ lifecycle: "outdated" })]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  assert.equal(
    window.document.querySelector("[data-ghpr-surface='github.page.finding-drawer']"),
    null,
    "a file whose diff is on the page must not fall back to the drawer"
  );
  const table = window.document.querySelector("table.diff-table");
  let card = window.document.querySelector(
    "[data-ghpr-surface='github.pr.files.file.header']"
  );
  assert.ok(card, "a file-level finding must mount at the file header");
  assert.equal(card.dataset.ghprFindingScope, "file");
  assert.equal(card.nextElementSibling, table, "the file-level card must sit above its diff");
  assert.ok(
    card.classList.contains("ghpr-review-finding"),
    "navigating to a file-level finding must open it in place"
  );
  assert.match(card.textContent, /File-level/, "the card must state that it is file-scoped");
  assert.match(card.textContent, /Outdated/);
  assert.match(card.textContent, /src\/index\.ts · L8-L10 · reviewed bbbbbbb/);
  assert.match(card.textContent, /The legacy path can return stale state/);
  assert.equal(
    window.document.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']"),
    null,
    "an unanchored finding must not be mounted on a diff row"
  );
  assert.ok([...card.querySelectorAll("button")]
    .some((button) => button.textContent === "Show reviewed revision"),
  "an outdated file-level finding must offer its reviewed revision");

  const collapse = [...card.querySelectorAll("button")]
    .find((button) => button.textContent === "Collapse");
  assert.ok(collapse);
  collapse.click();
  await settle();
  card = window.document.querySelector("[data-ghpr-surface='github.pr.files.file.header']");
  assert.equal(
    card.getAttribute("data-file-level"),
    "true",
    "collapsing must leave a compact card that is not the diff-line shape"
  );
  assert.equal(card.getAttribute("data-inline"), "false");
  assert.equal(card.nextElementSibling, table, "the compact card must stay above its diff");
  assert.match(card.textContent, /File-level/);
  assert.match(card.textContent, /The legacy helper can publish a stale cache entry/);

  card.click();
  await settle();
  card = window.document.querySelector("[data-ghpr-surface='github.pr.files.file.header']");
  assert.ok(card.classList.contains("ghpr-review-finding"), "clicking must expand the full finding in place");
  assert.deepEqual(gm.opened, [], "file-level findings must never open the local app");

  app.stop();
  window.close();
});

test("v2: a line-anchored finding whose row is not loaded yet stays out of the file-level band", async () => {
  const pathname = "/acme/widgets/pull/42/files";
  const window = await createWindow("files-unified.html", pathname);
  // The fixture diff renders lines 9-11 only; line 120 stands in for a row that
  // GitHub has not expanded or lazy-loaded yet.
  const snapshot = makeSnapshot(pathname, {
    findings: [persistedReviewFinding({
      subject: { start_line: 118, end_line: 120 }
    })]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  assert.equal(
    window.document.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']"),
    null,
    "the row is absent, so nothing mounts on the diff yet"
  );
  assert.equal(
    window.document.querySelector("[data-ghpr-surface='github.pr.files.file.header']"),
    null,
    "a pending line anchor must never be relabelled as a file-level finding"
  );

  app.stop();
  window.close();
});

test("v2: a finding for a file outside this diff still falls back to the drawer", async () => {
  const pathname = "/acme/widgets/pull/42/files?ghpr_finding=finding_1";
  const window = await createWindow("files-unified.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    findings: [persistedReviewFinding({
      lifecycle: "outdated",
      subject: { file_path: "src/absent.ts" }
    })]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const drawer = window.document.querySelector(
    "[data-ghpr-surface='github.page.finding-drawer']"
  );
  assert.ok(drawer, "a finding whose file is absent must open the in-page fallback drawer");
  assert.match(drawer.textContent, /outdated.*reviewed bbbbbbb/s);
  assert.ok([...drawer.querySelectorAll("button")]
    .some((button) => button.textContent === "View reviewed revision"));
  const reviewLatest = [...drawer.querySelectorAll("button")]
    .find((button) => button.textContent === "Review latest revision");
  assert.ok(reviewLatest);
  reviewLatest.click();
  window.document
    .querySelector("[data-ghpr-surface='github.pr.review-launch-dialog'] [data-action-id='start-review']")
    .click();
  await settle();
  const action = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map((request) => JSON.parse(request.data).action)
    .find((candidate) => candidate.skill_id === "pr.review");
  assert.equal(action.subject.type, "pull_request_revision");
  assert.deepEqual(gm.opened, [], "fallback revision actions must not open the local app");

  app.stop();
  window.close();
});

function newerRevisionSnapshot(pathname, overrides = {}) {
  return makeSnapshot(pathname, {
    current_revision_subject: {
      type: "pull_request_revision",
      repository: "acme/widgets",
      pr_number: 42,
      base_sha: "a".repeat(40),
      head_sha: "d".repeat(40)
    },
    ...overrides
  });
}

test("v2: an outdated finding offers the revision it was reviewed against", async () => {
  const pathname = "/acme/widgets/pull/42/files";
  const window = await createWindow("files-unified.html", pathname);
  const snapshot = newerRevisionSnapshot(pathname, {
    findings: [persistedReviewFinding({ lifecycle: "outdated" })]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const card = window.document.getElementById("ghpr-operation-card");
  assert.match(card.textContent, /Reviewed bbbbbbb/, "the card must bind the findings to their reviewed commit");
  assert.match(card.textContent, /Outdated · head ddddddd/, "a newer head must be reported as outdated findings");
  const viewReviewed = [...card.querySelectorAll("button")]
    .find((button) => button.textContent === "View reviewed revision");
  assert.ok(viewReviewed, "an outdated finding must be reachable at the revision it was reviewed against");
  viewReviewed.click();
  await settle();
  assert.equal(
    window.location.href,
    `https://github.com/acme/widgets/pull/42/files/${"a".repeat(40)}..${"b".repeat(40)}` +
      "?ghpr_finding=finding_1&path=src%2Findex.ts&line=10#L10"
  );
  assert.deepEqual(gm.opened, [], "revision navigation must stay in the page");

  app.stop();
  window.close();
});

test("v2: the reviewed revision's Files changed page anchors outdated findings in place", async () => {
  const pathname = `/acme/widgets/pull/42/files/${"a".repeat(40)}..${"b".repeat(40)}?ghpr_finding=finding_1`;
  const window = await createWindow("files-unified.html", pathname);
  const snapshot = newerRevisionSnapshot(pathname, {
    findings: [persistedReviewFinding({ lifecycle: "outdated" })]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  const additionCell = window.document.querySelector(".blob-code-addition");
  const marker = additionCell.querySelector("[data-ghpr-surface='github.pr.files.diff.line.after']");
  assert.ok(marker, "a finding reviewed at this commit must anchor on this revision's diff");
  assert.match(marker.textContent, /Reviewed revision/, "the card must state which revision it belongs to");
  assert.match(marker.textContent, /L8-L10/, "the card must state the reviewed line range");
  assert.equal(
    window.document.querySelector("[data-ghpr-surface='github.page.finding-drawer']"),
    null,
    "anchoring at the reviewed revision must replace the outdated-finding drawer fallback"
  );
  assert.ok(
    window.document.querySelector("[data-testid='ghpr-inline-finding-panel']"),
    "the requested finding must expand on the reviewed revision"
  );

  const card = window.document.getElementById("ghpr-operation-card");
  assert.match(card.textContent, /Outdated revision/);
  assert.match(card.textContent, /Findings from the reviewed revision bbbbbbb/);
  const back = [...card.querySelectorAll("button")]
    .find((button) => button.textContent === "Back to latest revision");
  assert.ok(back, "the reviewed revision view must offer a way back to the latest diff");
  back.click();
  await settle();
  assert.equal(window.location.href, "https://github.com/acme/widgets/pull/42/files");

  app.stop();
  window.close();
});

test("v2: reviewer rows preserve current completed results after failed attempts", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const currentHead = "a".repeat(40);
  const oldHead = "b".repeat(40);
  const snapshot = makeSnapshot(pathname, {
    current_revision_subject: {
      type: "pull_request_revision", repository: "acme/widgets", pr_number: 42,
      base_sha: "c".repeat(40), head_sha: currentHead
    },
    skills: [{ id: "pr.review", agents: ["codex", "claude_code"], is_runnable: true }],
    runs: [
      { id: "failed-codex", skill_id: "pr.review", agent: "codex", status: "failed", completed_at: "2026-08-24T00:03:00Z" },
      { id: "current-codex", skill_id: "pr.review", agent: "codex", status: "completed", completed_at: "2026-08-24T00:02:00Z", result: { code_review: { reviewed_head_sha: currentHead, findings: [{ id: "finding_1" }], overview_markdown: "Current result." } } },
      { id: "old-claude", skill_id: "pr.review", agent: "claude_code", status: "completed", completed_at: "2026-08-24T00:01:00Z", result: { code_review: { reviewed_head_sha: oldHead, findings: [{ id: "finding_1", title: "Old title", summary: "Old summary", details: "Old details", quoted_code: "old snippet" }], overview_markdown: "Old result." } } }
    ],
    findings: [persistedReviewFinding({ id: "finding_1" })]
  });
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();
  const summary = window.document.querySelector("[data-ghpr-surface='github.pr.conversation.review-summary']");
  const codex = summary.querySelector("[data-action-id='request-review-codex']")?.parentElement;
  assert.match(codex?.textContent || "", /Failed/);
  const result = codex?.querySelector("[aria-label='Open Codex review results']");
  assert.ok(result, "completed Codex history remains selectable after a failed retry");
  result.click();
  await settle();
  let mountedSummary = window.document.querySelector("[data-ghpr-surface='github.pr.conversation.review-summary']");
  assert.match(mountedSummary.textContent, /Current result/);
  const claude = mountedSummary.querySelector("[aria-label='Open Claude Code review results']");
  claude.click();
  await settle();
  mountedSummary = window.document.querySelector("[data-ghpr-surface='github.pr.conversation.review-summary']");
  assert.match(mountedSummary.textContent, /Old result/);
  assert.match(mountedSummary.textContent, /Old details/);
  app.stop();
  window.close();
});

test("v1: with github_surface_v2 false, legacy #ghpr-github-root and header entry remain", async () => {
  const pathname = "/acme/widgets/pull/42";
  const window = await createWindow("conversation.html", pathname);
  const snapshot = makeSnapshot(pathname, {
    github_surface_v2: false,
    analyses: [{
      id: "analysis-1",
      verdict: "likely_flaky",
      confidence: "high",
      summary: "The failed job matches prior flaky runs.",
      history_matches: [],
      history_checked: 12,
      relatedness_score: 0.1
    }]
  });
  window.confirm = () => {
    throw new Error("Legacy failed-check actions must not use browser confirm dialogs.");
  };
  const gm = new FakeGM({
    snapshot,
    discoveryV2: false,
    clientScopes: CLIENT.requested_scopes.filter((scope) => scope !== "skill:run")
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  await settle();

  assert.ok(window.document.getElementById("ghpr-github-root"), "v1 floating/sidebar card must still render");
  assert.ok(window.document.getElementById("ghpr-header-entry"), "v1 header entry must still render");
  assert.equal(window.document.querySelector("[data-ghpr-surface]"), null, "no v2 surfaces should mount when the flag is false");

  const rerun = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Rerun");
  assert.ok(rerun, "legacy rerun must not require the unrelated skill:run scope");
  rerun.click();
  const rerunDialog = window.document.querySelector(
    "[data-ghpr-surface='github.pr.review-launch-dialog']"
  );
  assert.ok(rerunDialog, "legacy rerun must use the ghpr modal");
  assert.equal(
    rerunDialog.querySelector("[data-action-id='explain-before-rerun']"),
    null,
    "legacy rerun hides Explain without skill:run"
  );
  rerunDialog.querySelector("[data-action-id='rerun-anyway']").click();
  await settle();
  const rerunRequest = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map((request) => JSON.parse(request.data))
    .find((body) => body.action?.kind === "rerun_failed_jobs");
  assert.equal(rerunRequest?.confirmed, true);

  app.stop();
  window.close();
});
