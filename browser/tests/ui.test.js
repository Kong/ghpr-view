import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Window } from "happy-dom";

globalThis.__GHPR_TEST__ = true;
await import("../ghpr.user.js");

const {
  CLIENT,
  createGhprApp,
  isVersionNewer,
  isConversationSurface,
  isFilesChangedSurface,
  filesChangedRevisionRef,
  parseGitHubPage,
  semanticTargets
} = globalThis.GhprUserscript;
const fixtureURL = new URL("./github-pr-fixture.html", import.meta.url);
const fixtureHTML = await readFile(fileURLToPath(fixtureURL), "utf8");
const userscriptSource = await readFile(
  new URL("../ghpr.user.js", import.meta.url),
  "utf8"
);

function jsonResponse(value, status = 200) {
  return {
    status,
    responseText: JSON.stringify(value)
  };
}

class FakeGM {
  constructor({
    online = true,
    paired = true,
    snapshot = makeSnapshot(),
    latestVersion = CLIENT.version,
    scopes = CLIENT.requested_scopes,
    pairingScopes = scopes,
    discoverySurfaceV2 = false
  } = {}) {
    this.online = online;
    this.snapshot = snapshot;
    this.latestVersion = latestVersion;
    this.scopes = [...scopes];
    this.pairingScopes = [...pairingScopes];
    this.discoverySurfaceV2 = discoverySurfaceV2;
    this.storage = new Map(paired ? [
      ["ghpr.bridge.port", 48120],
      ["ghpr.bridge.instance", "ghpr-test"],
      ["ghpr.bridge.token", "cap_test"]
    ] : []);
    this.requests = [];
    this.opened = [];
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

  async request(options) {
    this.requests.push(options);
    if (!this.online) throw new Error("offline");
    const url = new URL(options.url);
    if (url.pathname === "/.well-known/ghpr-browser-bridge") {
      return jsonResponse({
        protocol: "ghpr.browser-bridge/v1",
        instance_id: "ghpr-test",
        app_version: "1.0.0",
        official_userscript_version: this.latestVersion,
        api_versions: [1],
        pairing_required: true,
        github_surface_v2: this.discoverySurfaceV2,
      });
    }
    if (url.pathname === "/api/v1/pairings" && options.method === "POST") {
      return jsonResponse({
        request_id: "pair_permissions",
        pairing_secret: "pair_secret",
        pairing_url: "http://127.0.0.1:48120/ui/pair/pair_permissions?secret=pair_secret",
        expires_at: "2026-08-24T00:05:00Z"
      }, 201);
    }
    if (url.pathname === "/api/v1/pairings/pair_permissions") {
      this.scopes = [...this.pairingScopes];
      return jsonResponse({
        state: "approved",
        token: "cap_upgraded",
        client: {
          id: CLIENT.id,
          name: CLIENT.name,
          version: CLIENT.version,
          scopes: this.scopes,
          created_at: "2026-08-24T00:00:00Z",
          last_seen_at: "2026-08-24T00:00:00Z",
          revoked_at: null
        },
        error: null
      });
    }
    if (url.pathname === "/api/v1/client") {
      return jsonResponse({
        id: CLIENT.id,
        name: CLIENT.name,
        version: CLIENT.version,
        scopes: this.scopes,
        created_at: "2026-08-24T00:00:00Z",
        last_seen_at: "2026-08-24T00:00:00Z",
        revoked_at: null
      });
    }
    if (url.pathname === "/api/v1/page") return jsonResponse(this.snapshot);
    if (url.pathname === "/api/v1/actions") {
      const body = JSON.parse(options.data);
      const action = body.action;
      const detailURL = action.kind === "open_detail" && action.run_id
        ? `http://127.0.0.1:48120/ui/run/${action.run_id}?cap=detail_cap`
        : null;
      return jsonResponse({
        run: null,
        url: detailURL,
        tags: [],
        rerun_count: null,
        event: null
      });
    }
    if (url.pathname === "/api/v1/slot-health") return jsonResponse({ ok: true });
    if (url.pathname.includes("/contributions/") && url.pathname.endsWith("/invoke")) {
      return jsonResponse({ run: null, url: null, tags: null, rerun_count: null, event: null });
    }
    throw new Error(`Unhandled fake request: ${options.method} ${url.pathname}`);
  }
}

function makeSnapshot() {
  const page = {
    type: "pull_request",
    key: "github:example-org/example-repo:pr:1238",
    repository: "example-org/example-repo",
    pr_number: 1238,
    workflow_run_id: null
  };
  return {
    page,
    pull_request: {
      id: 1238,
      repository: "example-org/example-repo",
      number: 1238,
      title: "Make CI history comparison deterministic",
      ci_status: "FAILURE"
    },
    analyses: [{
      id: "analysis_1",
      page_key: page.key,
      repository: "example-org/example-repo",
      pr_number: 1238,
      job_name: "unit-test",
      verdict: "likely_flaky",
      confidence: "high",
      confidence_score: 0.92,
      summary: "The same signature appeared in three main-branch runs.",
      history_matches: [
        {
          id: "history_1",
          run_number: 71,
          branch: "main",
          date: "2026-08-23T00:00:00Z",
          similarity: 0.96,
          result: "failure"
        }
      ],
      history_checked: 20,
      relatedness_score: 0.12,
      relatedness_summary: "No changed file overlaps the failing package.",
      reproduction: "Not rerun",
      failure_signature: "unit-test:timeout",
      changed_files: ["README.md"],
      suggested_action: "Rerun failed jobs",
      agent: "codex",
      strict_context: true,
      duration_seconds: 34,
      created_at: "2026-08-24T00:00:00Z"
    }],
    tags: ["needs_investigation"],
    runs: [],
    skills: [
      {
        id: "ci.failure.classify_flaky",
        version: "1.0.0",
        display_name: "Classify Flaky",
        summary: "Classify a failed check.",
        targets: ["pull_request"],
        agents: ["codex"],
        default_agent: "codex",
        is_built_in: true,
        has_browser_companion: false,
        is_runnable: true
      },
      {
        id: "team.ci.policy-check",
        version: "1.0.0",
        display_name: "Run Team Policy",
        summary: "Run the team policy check.",
        targets: ["pull_request"],
        agents: ["codex"],
        default_agent: "codex",
        is_built_in: false,
        has_browser_companion: false,
        is_runnable: true
      }
    ],
    contributions: [{
      id: "team-policy",
      client_id: "com.example.team-ci-helper",
      page_key: page.key,
      slot: "files.toolbar.actions",
      component: {
        type: "action",
        label: "Run Team Policy Check",
        text: null,
        tone: "analysis",
        presentation_ref: null
      },
      action: {
        kind: "client_event",
        skill_id: null,
        run_id: null,
        analysis_id: null,
        tag: null,
        event: "team-policy-check:clicked"
      },
      created_at: "2026-08-24T00:00:00Z",
      expires_at: "2026-08-24T00:05:00Z"
    }]
  };
}

function createWindow(pathname = "/example-org/example-repo/pull/1238/checks") {
  const window = new Window({ url: `https://github.com${pathname}` });
  window.document.write(fixtureHTML);
  window.document.close();
  window.confirm = () => true;
  return window;
}

function setViewport(window, width, height) {
  Object.defineProperties(window, {
    innerWidth: { configurable: true, value: width },
    innerHeight: { configurable: true, value: height }
  });
  Object.defineProperties(window.document.documentElement, {
    clientWidth: { configurable: true, value: width },
    clientHeight: { configurable: true, value: height }
  });
}

function actionBody(request) {
  return JSON.parse(request.data);
}

async function settle() {
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
}

function openHeaderMenu(window) {
  const entry = window.document.getElementById("ghpr-header-entry");
  const menu = entry?.querySelector(".ghpr-header-menu");
  if (menu?.hidden) entry.querySelector(".ghpr-header-button").click();
  return menu;
}

test("parses supported GitHub PR and workflow URLs", () => {
  assert.deepEqual(
    parseGitHubPage(new URL("https://github.com/Example-Org/example-repo/pull/1238/files")),
    {
      type: "pull_request",
      key: "github:example-org/example-repo:pr:1238",
      repository: "Example-Org/example-repo",
      pr_number: 1238,
      workflow_run_id: null
    }
  );
  assert.deepEqual(
    parseGitHubPage(new URL("https://github.com/example-org/example-repo/actions/runs/9988")),
    {
      type: "workflow_run",
      key: "github:example-org/example-repo:run:9988",
      repository: "example-org/example-repo",
      pr_number: null,
      workflow_run_id: 9988
    }
  );
  assert.equal(
    parseGitHubPage(new URL("https://github.com/example-org/example-repo/issues/7")),
    null
  );
});

test("compares server userscript versions without false update prompts", () => {
  assert.equal(isVersionNewer("1.2.1", "1.2.0"), true);
  assert.equal(isVersionNewer("1.1.1", "1.1.1"), false);
  assert.equal(isVersionNewer("1.1.0", "1.1.1"), false);
  assert.equal(isVersionNewer("not-a-version", "1.1.1"), false);
});
test("publishes the client and update metadata as userscript v2.0.14", () => {
  const metadataVersion = userscriptSource.match(/^\/\/ @version\s+(\S+)$/m)?.[1];
  assert.equal(metadataVersion, "2.0.14");
  assert.equal(CLIENT.version, metadataVersion);
  assert.equal(CLIENT.requested_scopes.includes("tag:read"), true);
  assert.equal(CLIENT.requested_scopes.includes("tag:write"), true);
});

test("disables the run control of a Skill that is already running", async () => {
  const snapshot = makeSnapshot();
  snapshot.runs = [{
    id: "run_active",
    skill_id: "ci.failure.classify_flaky",
    page: snapshot.page,
    requested_by_client_id: CLIENT.id,
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:01Z",
    completed_at: null,
    status: "running",
    progress_message: "Executing Skill",
    progress_current: null,
    progress_total: null,
    log_entries: [],
    result: null,
    error: null,
    retry_of_run_id: null
  }];
  const window = createWindow();
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const menu = openHeaderMenu(window);
  const controls = [...menu.querySelectorAll(".ghpr-panel-action")];
  const busy = controls.find((control) => control.textContent.startsWith("Classify Flaky"));
  const idle = controls.find((control) => control.textContent.startsWith("Explain CI Failure"));
  assert.equal(busy?.textContent, "Classify Flaky · Running");
  assert.equal(busy?.disabled, true);
  assert.equal(busy?.getAttribute("aria-disabled"), "true");
  assert.equal(idle?.textContent, "Explain CI Failure");
  assert.equal(idle?.disabled, false);

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

test("a repeated run click submits the Skill once", async () => {
  const window = createWindow();
  const gm = new FakeGM();
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const control = [...openHeaderMenu(window).querySelectorAll(".ghpr-panel-action")]
    .find((candidate) => candidate.textContent === "Classify Flaky");
  control.click();
  control.click();
  control.click();
  await settle();

  const submitted = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map(actionBody)
    .filter((body) => body.action.kind === "run_skill");
  assert.equal(submitted.length, 1);
  assert.equal(submitted[0].action.skill_id, "ci.failure.classify_flaky");
  assert.equal(control.disabled, true);

  app.stop();
  window.close();
});


test("prompts for a userscript update reported by the Browser Bridge", async () => {
  const window = createWindow();
  const gm = new FakeGM({ latestVersion: "2.1.0" });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const menu = openHeaderMenu(window);
  const notice = menu.querySelector(".ghpr-update-notice");
  assert.match(notice?.textContent || "", /Userscript update available.*2\.0\.14 → 2\.1\.0/s);
  notice.querySelector("button").click();
  assert.deepEqual(gm.opened, ["http://127.0.0.1:48120/install/ghpr.user.js"]);

  app.stop();
  window.close();
});

test("classifies only PR conversation URLs as the expanded surface", () => {
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42")),
    true
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42/conversation")),
    true
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42/checks")),
    false
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/pull/42/files")),
    false
  );
  assert.equal(
    isConversationSurface(new URL("https://github.com/example/repo/actions/runs/9988")),
    false
  );
});

test("classifies both GitHub Files changed routes and their reviewed revisions", () => {
  assert.equal(
    isFilesChangedSurface(new URL("https://github.com/example/repo/pull/42/files")),
    true
  );
  assert.equal(
    isFilesChangedSurface(new URL("https://github.com/example/repo/pull/42/changes")),
    true
  );
  assert.equal(
    isFilesChangedSurface(new URL("https://github.com/example/repo/pull/42/checks")),
    false
  );
  const base = "a".repeat(40);
  const head = "b".repeat(40);
  assert.equal(
    isFilesChangedSurface(new URL(`https://github.com/example/repo/pull/42/files/${base}..${head}`)),
    true
  );
  assert.equal(
    filesChangedRevisionRef(new URL(`https://github.com/example/repo/pull/42/files/${base}..${head}`)),
    head
  );
  assert.equal(
    filesChangedRevisionRef(new URL(`https://github.com/example/repo/pull/42/files/${head}`)),
    head
  );
  assert.equal(
    filesChangedRevisionRef(new URL("https://github.com/example/repo/pull/42/files")),
    null
  );
});

test("finds semantic anchors without depending on one GitHub selector", () => {
  const window = createWindow();
  assert.equal(semanticTargets(window.document, "pr.header.actions").length, 1);
  assert.equal(semanticTargets(window.document, "checks.run.trailing").length, 2);
  assert.equal(semanticTargets(window.document, "files.toolbar.actions").length, 0);
  window.close();
});
test("renders an independent ghpr header menu while unpaired", async () => {
  const window = createWindow();
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ paired: false })
  });
  await app.start();

  const entry = window.document.querySelector("[data-testid='issue-header'] #ghpr-header-entry");
  assert.ok(entry, "ghpr should add a compact entry to the GitHub PR header");
  assert.equal(entry.querySelector("button")?.textContent, "ghpr ▾");
  const menu = entry.querySelector(".ghpr-header-menu");
  assert.equal(menu.hidden, true);
  entry.querySelector(".ghpr-header-button").click();
  assert.equal(menu.hidden, false);
  assert.match(menu.textContent, /Connect this userscript/);

  app.stop();
  window.close();
});
test("offers Bridge pairing through a Tampermonkey command when v2 leaves GitHub DOM untouched", async () => {
  const window = createWindow();
  const gm = new FakeGM({
    paired: false,
    discoverySurfaceV2: true,
    snapshot: { ...makeSnapshot(), github_surface_v2: true }
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  assert.ok(window.document.getElementById("ghpr-header-entry"), "the compact entry stays available for Connect");
  const connect = gm.commands.get("Connect ghpr");
  assert.equal(typeof connect, "function");

  await connect();
  assert.ok(
    gm.requests.some((request) =>
      request.method === "POST" && new URL(request.url).pathname === "/api/v1/pairings"
    )
  );
  assert.equal(gm.storage.get("ghpr.bridge.token"), "cap_upgraded");

  app.stop();
  window.close();
});
test("mounts the ghpr entry before the modern GitHub profile control", async () => {
  const window = createWindow();
  window.document.querySelector(".gh-header-actions")?.remove();
  const header = window.document.createElement("header");
  header.innerHTML = `
    <div class="AppHeader-globalBar-end">
      <button id="native-action">Native action</button>
      <button class="AppHeader-user" aria-label="Open user navigation menu">Profile</button>
    </div>
  `;
  window.document.body.prepend(header);
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ paired: false })
  });
  await app.start();

  const globalActions = window.document.querySelector(".AppHeader-globalBar-end");
  const profile = globalActions.querySelector(".AppHeader-user");
  const entry = window.document.getElementById("ghpr-header-entry");
  assert.equal(entry.parentElement, globalActions);
  assert.equal(profile.previousElementSibling, entry);
  assert.equal(entry.classList.contains("ghpr-header-floating"), false);

  app.stop();
  window.close();
});



test("checks page leaves the GitHub sidebar alone and keeps actions in the menu", async () => {
  const window = createWindow();
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM()
  });
  await app.start();

  const sidebar = window.document.querySelector("#partial-discussion-sidebar");
  const reviewers = sidebar.querySelector("[data-testid='reviewers-section']");
  const assignees = sidebar.querySelector("[data-testid='assignees-section']");
  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  assert.equal(reviewers.nextElementSibling, assignees, "ghpr must not insert a card between Reviewers and Assignees");
  assert.equal(window.document.querySelector("[aria-label='ghpr CI Analysis']"), null);
  const entry = window.document.querySelector("[data-testid='issue-header'] #ghpr-header-entry");
  assert.ok(entry, "the compact entry belongs in the PR header");
  assert.equal(entry.querySelector(".ghpr-header-menu").hidden, true);

  const menu = openHeaderMenu(window);
  assert.match(menu.textContent, /Likely flaky/);
  assert.match(menu.textContent, /Explain CI Failure/);
  await app.refresh();
  assert.equal(menu.hidden, false, "polling must not close the menu the user opened");

  app.stop();
  window.close();
});

test("conversation stays collapsed until Review results is opened", async () => {
  const window = createWindow("/example-org/example-repo/pull/1238");
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM()
  });
  await app.start();

  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  assert.equal(window.document.querySelector("[aria-label='ghpr CI Analysis']"), null);
  const menu = openHeaderMenu(window);
  const toggle = menu.querySelector(".ghpr-review-results-toggle");
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
  assert.match(menu.textContent, /Likely flaky/);

  app.stop();
  window.close();
});

test("falls back to a floating entry when GitHub has no header host", async () => {
  const window = createWindow();
  window.document.querySelector("#partial-discussion-sidebar")?.remove();
  for (const host of window.document.querySelectorAll(
    ".gh-header-actions, .gh-header-show, .AppHeader-globalBar-end, header"
  )) {
    host.remove();
  }
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM()
  });
  await app.start();

  const entry = window.document.getElementById("ghpr-header-entry");
  assert.equal(entry.parentElement, window.document.body);
  assert.ok(entry.classList.contains("ghpr-header-floating"));
  assert.equal(window.document.getElementById("ghpr-github-root"), null);

  app.stop();
  window.close();
});

test("mounts the ghpr entry in the current GitHub global bar", async () => {
  const window = createWindow();
  window.document.querySelector(".gh-header-actions")?.remove();
  const header = window.document.createElement("header");
  header.innerHTML = `
    <div data-testid="top-nav-right">
      <button class="AppHeader-user" aria-label="Open user navigation menu">Profile</button>
    </div>
  `;
  window.document.body.prepend(header);
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ paired: false })
  });
  await app.start();

  const globalActions = window.document.querySelector("[data-testid='top-nav-right']");
  const entry = window.document.getElementById("ghpr-header-entry");
  assert.equal(entry.parentElement, globalActions);
  assert.equal(globalActions.querySelector(".AppHeader-user").previousElementSibling, entry);
  assert.equal(entry.classList.contains("ghpr-header-floating"), false);

  app.stop();
  window.close();
});

test("keeps the header menu inside a narrow viewport", async () => {
  const window = createWindow();
  setViewport(window, 558, 683);
  const app = createGhprApp({
    window,
    document: window.document,
    gm: new FakeGM({ paired: false })
  });
  await app.start();

  const entry = window.document.getElementById("ghpr-header-entry");
  const button = entry.querySelector(".ghpr-header-button");
  button.getBoundingClientRect = () => ({
    left: 500, right: 590, top: 72, bottom: 104, width: 90, height: 32, x: 500, y: 72
  });
  app.renderHeaderEntry();
  assert.equal(entry.parentElement, window.document.body);
  assert.ok(entry.classList.contains("ghpr-header-floating"));
  assert.ok(entry.classList.contains("ghpr-header-floating-narrow"));

  button.getBoundingClientRect = () => ({
    left: 478, right: 550, top: 8, bottom: 40, width: 72, height: 32, x: 478, y: 8
  });
  button.click();
  const menu = entry.querySelector(".ghpr-header-menu") ||
    window.document.querySelector(".ghpr-header-menu");
  const left = parseFloat(menu.style.left);
  const width = parseFloat(menu.style.width);
  assert.equal(menu.hidden, false);
  assert.ok(left >= 8, `menu left ${left} should stay inside the viewport`);
  assert.ok(left + width <= 550, `menu right ${left + width} should stay inside the viewport`);
  assert.equal(menu.style.getPropertyValue("height"), "auto");
  assert.equal(menu.style.getPropertyValue("bottom"), "auto");
  assert.equal(menu.style.getPropertyValue("position"), "fixed");

  app.stop();
  window.close();
});


test("renders failed-check actions, local tags, and contribution fallback on PR checks", async () => {
  const window = createWindow();
  const gm = new FakeGM();
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  const headerEntry = window.document.getElementById("ghpr-header-entry");
  assert.ok(headerEntry, "ghpr should mount a header entry on authenticated PR pages");
  headerEntry.querySelector(".ghpr-header-button").click();
  const menu = headerEntry.querySelector(".ghpr-header-menu");
  assert.match(
    menu?.textContent || "",
    /Explain CI Failure.*Classify Flaky.*Run Skill.*Run Team Policy.*Tags.*Needs investigation/s
  );
  assert.equal(window.document.querySelector("[aria-label='ghpr CI Analysis']"), null);
  const failedRow = window.document.querySelectorAll("[data-testid='check-run-row']")[0];
  const successRow = window.document.querySelectorAll("[data-testid='check-run-row']")[1];
  assert.doesNotMatch(failedRow.textContent, /Analyze/);
  assert.doesNotMatch(successRow.textContent, /Analyze/);
  assert.match(
    menu.textContent,
    /Extensions.*Run Team Policy Check/s,
    "missing semantic anchors fall back into the header menu"
  );

  const health = gm.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/slot-health")
    .map((request) => JSON.parse(request.data));
  assert.ok(
    health.some((report) =>
      report.slot === "files.toolbar.actions" && report.healthy === false
    ),
    "missing semantic anchors must be reported and fall back to the ghpr card"
  );

  const classify = [...menu.querySelectorAll(".ghpr-panel-action")]
    .find((element) => element.textContent === "Classify Flaky");
  classify.click();
  await settle();
  const action = gm.requests.find((request) =>
    new URL(request.url).pathname === "/api/v1/actions"
  );
  assert.deepEqual(actionBody(action).action, {
    kind: "run_skill",
    skill_id: "ci.failure.classify_flaky"
  });

  app.stop();
  window.close();
});

test("shows an active Skill run and opens its live log from GitHub surfaces", async () => {
  const snapshot = makeSnapshot();
  snapshot.runs = [{
    id: "run_live",
    skill_id: "ci.failure.explain",
    page: snapshot.page,
    requested_by_client_id: CLIENT.id,
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:01Z",
    completed_at: null,
    status: "running",
    progress_message: "Comparing failure history",
    progress_current: 2,
    progress_total: 3,
    log_entries: [
      {
        timestamp: "2026-08-24T00:00:01Z",
        kind: "running",
        message: "Comparing failure history"
      }
    ],
    result: null,
    error: null,
    retry_of_run_id: null
  }];
  const checksWindow = createWindow();
  const checksGM = new FakeGM({ snapshot });
  const checksApp = createGhprApp({
    window: checksWindow,
    document: checksWindow.document,
    gm: checksGM
  });
  await checksApp.start();

  const menu = openHeaderMenu(checksWindow);
  const failedRow = checksWindow.document.querySelectorAll("[data-testid='check-run-row']")[0];
  assert.doesNotMatch(failedRow.textContent, /View log|Analyze/);
  assert.match(menu.textContent, /Explain CI Failure · Running/);
  const view = [...menu.querySelectorAll("button")].find((button) => button.textContent === "View live log");
  assert.ok(view, "an active run stays reachable from the menu");
  view.click();
  await settle();
  const detailAction = checksGM.requests
    .filter((request) => new URL(request.url).pathname === "/api/v1/actions")
    .map(actionBody)
    .find((body) => body.action.kind === "open_detail");
  assert.deepEqual(detailAction?.action, {
    kind: "open_detail",
    run_id: "run_live"
  });
  assert.deepEqual(checksGM.opened, [
    "http://127.0.0.1:48120/ui/run/run_live?cap=detail_cap"
  ]);

  const conversationWindow = createWindow("/example-org/example-repo/pull/1238");
  const conversationApp = createGhprApp({
    window: conversationWindow,
    document: conversationWindow.document,
    gm: new FakeGM({ snapshot })
  });
  await conversationApp.start();
  assert.equal(conversationWindow.document.querySelector("[aria-label='ghpr Skill Running']"), null);
  const conversationMenu = openHeaderMenu(conversationWindow);
  assert.match(conversationMenu.textContent, /View live log/);
  assert.equal(
    conversationWindow.document.querySelector("[aria-label='ghpr CI Analysis']"),
    null
  );

  checksApp.stop();
  conversationApp.stop();
  checksWindow.close();
  conversationWindow.close();
});

test("does not expose PR-only analysis actions on workflow run pages", async () => {
  const snapshot = makeSnapshot();
  snapshot.page = {
    type: "workflow_run",
    key: "github:example-org/example-repo:run:987",
    repository: "example-org/example-repo",
    pr_number: null,
    workflow_run_id: 987
  };
  const window = createWindow("/example-org/example-repo/actions/runs/987");
  const jobHost = window.document.createElement("div");
  jobHost.setAttribute("data-testid", "check-job-row");
  window.document.body.append(jobHost);
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const text = openHeaderMenu(window)?.textContent || "";
  assert.doesNotMatch(text, /Explain CI Failure|Classify Flaky|Run Skill/);
  gm.commands.get("Analyze current PR")();
  await settle();
  assert.equal(
    gm.requests.some((request) => new URL(request.url).pathname === "/api/v1/actions"),
    false
  );

  app.stop();
  window.close();
});

test("offers permission repair instead of actions when skill:run is not granted", async () => {
  const scopes = CLIENT.requested_scopes.filter((scope) => scope !== "skill:run");
  const window = createWindow();
  const snapshot = makeSnapshot();
  const contribution = {
    id: "scope-gated-run-skill",
    client_id: CLIENT.id,
    page_key: snapshot.page.key,
    slot: "pr.header.actions",
    component: {
      type: "action",
      label: "Run Scope-Gated Skill",
      text: null,
      tone: "analysis",
      presentation_ref: null
    },
    action: {
      kind: "run_skill",
      skill_id: "ci.failure.classify_flaky",
      run_id: null,
      analysis_id: null,
      tag: null,
      event: null
    },
    created_at: "2026-08-24T00:00:00Z",
    expires_at: null
  };
  snapshot.contributions.push(contribution);
  const gm = new FakeGM({
    scopes,
    pairingScopes: CLIENT.requested_scopes,
    snapshot
  });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();
  const panel = openHeaderMenu(window);

  assert.match(panel?.textContent || "", /skill:run required.*Grant Run Skills/s);
  assert.doesNotMatch(panel?.textContent || "", /Explain CI Failure|Classify Flaky/);
  const failedRow = window.document.querySelectorAll("[data-testid='check-run-row']")[0];
  assert.doesNotMatch(failedRow.textContent, /Analyze/);
  const contributionGrant = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Grant Run Skill");
  assert.equal(Boolean(contributionGrant), true);
  await app.invokeAction({
    kind: "run_skill",
    skill_id: "ci.failure.classify_flaky"
  });
  assert.equal(
    gm.requests.some((request) => new URL(request.url).pathname === "/api/v1/actions"),
    false,
    "The userscript must not send a known unauthorized action."
  );
  assert.match(
    window.document.querySelector(".ghpr-error")?.textContent || "",
    /skill:run is not granted/
  );
  await app.invokeContribution(contribution);
  assert.equal(
    gm.requests.some((request) =>
      new URL(request.url).pathname.includes("/contributions/CLIENT_TEST/scope-gated-run-skill/invoke")
    ),
    false,
    "The userscript must not invoke a managed contribution with a missing scope."
  );

  const grant = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Grant Run Skills");
  grant.click();
  await settle();
  assert.deepEqual(gm.opened, [
    "http://127.0.0.1:48120/ui/pair/pair_permissions?secret=pair_secret&return=https%3A%2F%2Fgithub.com%2Fexample-org%2Fexample-repo%2Fpull%2F1238%2Fchecks"
  ]);
  const pairingRequest = gm.requests.find((request) =>
    request.method === "POST" && new URL(request.url).pathname === "/api/v1/pairings"
  );
  assert.deepEqual(JSON.parse(pairingRequest.data).required_scopes, ["skill:run"]);
  assert.equal(
    gm.requests.some((request) => new URL(request.url).pathname === "/api/v1/actions"),
    false,
    "Approval must not replay the blocked action"
  );
  const grantedContributionButton = [...window.document.querySelectorAll("button")]
    .find((button) => button.textContent === "Run Scope-Gated Skill");
  assert.equal(grantedContributionButton?.disabled, false);
  app.stop();
  window.close();
});

test("renders declarative result cards and invokes them with page-scoped identity", async () => {
  const snapshot = makeSnapshot();
  snapshot.contributions.push({
    id: "skill.dev.example.static-review.result",
    client_id: CLIENT.id,
    page_key: snapshot.page.key,
    slot: "pr.mergebox.after",
    component: {
      type: "result_card",
      label: "Static Review",
      text: "<b>One actionable finding</b>",
      tone: "analysis",
      presentation_ref: "result.summary"
    },
    action: {
      kind: "open_detail",
      skill_id: null,
      run_id: "run_review",
      analysis_id: null,
      tag: null,
      event: null
    },
    created_at: "2026-08-24T00:00:00Z",
    expires_at: "2026-08-24T00:05:00Z"
  });
  snapshot.runs = [{
    id: "run_review",
    skill_id: "dev.example.static-review",
    page: snapshot.page,
    requested_by_client_id: CLIENT.id,
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:01Z",
    completed_at: "2026-08-24T00:00:03Z",
    status: "completed",
    progress_message: "Completed",
    progress_current: 3,
    progress_total: 3,
    result: {
      kind: "code_review",
      title: "Static Review",
      summary: "One actionable finding",
      analysis: null,
      code_review: null,
      markdown: "One actionable finding",
      artifacts: []

    },
    error: null,
    retry_of_run_id: null
  }];
  const window = createWindow();
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const menu = openHeaderMenu(window);
  const card = window.document.querySelector("[aria-label='Static Review']");
  const control = card?.querySelector("button")
    || [...menu.querySelectorAll("button")].find((button) => button.textContent === "Static Review");
  assert.ok(control, "a contribution with no native anchor falls back into the menu");
  assert.equal(window.document.querySelector("b"), null, "Skill text must remain inert");
  control.click();
  await settle();

  const invoke = gm.requests.find((request) =>
    new URL(request.url).pathname.includes("/contributions/") &&
    new URL(request.url).pathname.endsWith("/invoke")
  );
  assert.ok(invoke);
  assert.equal(new URL(invoke.url).searchParams.get("page_key"), snapshot.page.key);
  assert.equal(window.document.getElementById("ghpr-github-root"), null);

  app.stop();
  window.close();
});

test("renders structured review findings in the collapsed review results", async () => {
  const snapshot = makeSnapshot();
  snapshot.runs = [{
    id: "run_review_findings",
    skill_id: "dev.example.static-review",
    page: snapshot.page,
    requested_by_client_id: CLIENT.id,
    created_at: "2026-08-24T00:00:00Z",
    started_at: "2026-08-24T00:00:01Z",
    completed_at: "2026-08-24T00:00:03Z",
    status: "completed",
    progress_message: "Completed",
    progress_current: 3,
    progress_total: 3,
    result: {
      kind: "code_review",
      title: "Review",
      summary: "Two actionable findings.",
      analysis: null,
      code_review: {
        overview_markdown: "Two actionable findings.",
        head_sha: "abc123",
        engine: "codex",
        reviewed_at: "2026-08-24T00:00:00Z",
        findings: [{
          id: "finding-1",
          file: "Sources/App.swift",
          line: 42,
          body: "Handle the error before continuing.",
          quoted_code: "try await request()",
          severity: "warning",
          confidence: 0.88,
          category: "correctness",
          details: {
            why: "The request failure is otherwise discarded.",
            suggested_fix: "Return the error.",
            background: null,
            trigger_scenarios: []
          }
        }]
      },
      markdown: "Two actionable findings.",
      artifacts: []
    },
    error: null,
    retry_of_run_id: null
  }];
  snapshot.findings = [{
    id: "finding-1",
    title: "Handle the error",
    summary: "The request failure is otherwise discarded.",
    severity: "warning",
    lifecycle: "exact",
    subject: {
      file_path: "Sources/App.swift",
      start_line: 42,
      end_line: 42,
      side: "addition",
      head_sha: "a".repeat(40)
    }
  }];
  const window = createWindow("/example-org/example-repo/pull/1238");
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const menu = openHeaderMenu(window);
  menu.querySelector(".ghpr-review-results-toggle").click();
  const finding = menu.querySelector(".ghpr-review-finding");
  assert.match(finding?.textContent || "", /Handle the error/);
  assert.match(finding?.textContent || "", /Sources\/App\.swift/);
  const view = [...finding.querySelectorAll("button")].find((button) => button.textContent === "View diff context");
  assert.equal(view?.textContent, "View diff context");
  const dismiss = [...finding.querySelectorAll("button")].find((button) => button.textContent === "Dismiss");
  assert.equal(dismiss?.textContent, "Dismiss");

  app.stop();
  window.close();
});
test("renders untrusted analysis text without creating active markup", async () => {
  const snapshot = makeSnapshot();
  snapshot.analyses[0].summary = "<img src=x onerror='globalThis.pwned=true'>";
  const window = createWindow("/example-org/example-repo/pull/1238");
  const gm = new FakeGM({ snapshot });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  const menu = openHeaderMenu(window);
  assert.equal(window.document.querySelector("img"), null, "untrusted analysis text must not become markup");
  assert.equal(menu.querySelector("img"), null);

  app.stop();
  window.close();
});

test("stays silent when ghpr-view is offline", async () => {
  const window = createWindow();
  const gm = new FakeGM({ online: false });
  const app = createGhprApp({ window, document: window.document, gm });
  await app.start();

  assert.equal(window.document.getElementById("ghpr-github-root"), null);
  assert.equal(window.document.getElementById("ghpr-header-entry"), null);
  assert.equal(window.document.querySelector("[data-ghpr-managed]"), null);

  app.stop();
  window.close();
});
