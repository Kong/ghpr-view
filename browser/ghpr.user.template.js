// ==UserScript==
// @name         ghpr for GitHub
// @namespace    https://github.com/xiaocang/ghpr-view
// @version      2.0.14
// @description  Run local ghpr Skills and render their results on GitHub pull requests.
// @match        https://github.com/*/*/pull/*
// @match        https://github.com/*/*/actions/runs/*
// @grant        GM.xmlHttpRequest
// @grant        GM.openInTab
// @grant        GM.registerMenuCommand
// @grant        GM.getValue
// @grant        GM.setValue
// @grant        GM.setClipboard
// @connect      localhost
// @connect      127.0.0.1
// @run-at       document-idle
// ==/UserScript==

(function ghprUserscriptModule(global) {
  "use strict";

  const CLIENT = {
    id: "dev.ghpr.official-userscript",
    name: "ghpr for GitHub",
    version: "2.0.14",
    requested_scopes: [
      "pr:read",
      "ci:read",
      "analysis:read",
      "skill:list",
      "skill:run",
      "skill:cancel",
      "tag:read",
      "tag:write",
      "ui:contribute",
      "detail:open",
      "app:open",
      "finding:write"
    ]
  };
  const DISCOVERY_PORTS = Array.from({ length: 10 }, (_, index) => 48120 + index);
  const STORAGE = {
    port: "ghpr.bridge.port",
    instance: "ghpr.bridge.instance",
    token: "ghpr.bridge.token"
  };
  const PERMISSION_LABELS = {
    "skill:run": "Run configured Skills",
    "skill:cancel": "Cancel Skill runs",
    "tag:write": "Change locally stored ghpr tags",
    "detail:open": "Open local analysis",
    "finding:write": "Dismiss review findings",
    "app:open": "Open ghpr-view"
  };
  const ROOT_ID = "ghpr-github-root";
  const HEADER_ENTRY_ID = "ghpr-header-entry";
  const OPERATION_CARD_ID = "ghpr-operation-card";
  const STYLE_ID = "ghpr-github-styles";
  const MANAGED_ATTRIBUTE = "data-ghpr-managed";
  const POLL_ACTIVE_MS = 2000;
  const POLL_IDLE_MS = 15000;
  // Discovery probes every port in turn, so it must fail fast. The page
  // snapshot resolves the current PR revision through the GitHub CLI, which
  // on large pull requests takes far longer than a discovery probe.
  const REQUEST_TIMEOUT_MS = 4000;
  const SNAPSHOT_TIMEOUT_MS = 20000;

  class BridgeError extends Error {
    constructor(message, status = 0, payload = null) {
      super(message);
      this.name = "BridgeError";
      this.status = status;
      this.payload = payload;
    }
  }

  function parseGitHubPage(locationLike) {
    const pathname = locationLike.pathname || "/";
    let match = pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)(?:\/|$)/);
    if (match) {
      const repository = `${decodeURIComponent(match[1])}/${decodeURIComponent(match[2])}`;
      const number = Number(match[3]);
      return {
        type: "pull_request",
        key: `github:${repository.toLowerCase()}:pr:${number}`,
        repository,
        pr_number: number,
        workflow_run_id: null
      };
    }
    match = pathname.match(/^\/([^/]+)\/([^/]+)\/actions\/runs\/(\d+)(?:\/|$)/);
    if (match) {
      const repository = `${decodeURIComponent(match[1])}/${decodeURIComponent(match[2])}`;
      const runID = Number(match[3]);
      return {
        type: "workflow_run",
        key: `github:${repository.toLowerCase()}:run:${runID}`,
        repository,
        pr_number: null,
        workflow_run_id: runID
      };
    }
    return null;
  }

  // `global.GM` finds Tampermonkey/Violentmonkey, which attach GM to the real
  // global object. Userscript sandboxes that instead pass GM as a closure
  // parameter (no global property) still resolve the bare identifier via
  // lexical scope, so try that first; `typeof` never throws when GM is absent.
  function createGMAdapter(source = (typeof GM !== "undefined" ? GM : global.GM) || {}) {
    const legacy = global;
    const getValue = source.getValue || legacy.GM_getValue;
    const setValue = source.setValue || legacy.GM_setValue;
    const openInTab = source.openInTab || legacy.GM_openInTab;
    const registerMenuCommand = source.registerMenuCommand || legacy.GM_registerMenuCommand;
    const xmlHttpRequest = source.xmlHttpRequest || legacy.GM_xmlhttpRequest;
    const setClipboard = source.setClipboard || legacy.GM_setClipboard;

    return {
      getValue: (key, fallback) => Promise.resolve(
        getValue ? getValue.call(source, key, fallback) : fallback
      ),
      setValue: (key, value) => Promise.resolve(
        setValue ? setValue.call(source, key, value) : undefined
      ),
      openInTab: (url) => {
        if (openInTab) {
          return openInTab.call(source, url, { active: true, insert: true });
        }
        return global.open(url, "_blank", "noopener");
      },
      // Tampermonkey's clipboard write does not need document focus or the
      // async Clipboard API permission, so it is preferred when granted.
      setClipboard: setClipboard
        ? (text) => Promise.resolve(setClipboard.call(source, text, "text/plain"))
        : null,
      registerMenuCommand: (label, callback) => {
        if (registerMenuCommand) {
          registerMenuCommand.call(source, label, callback);
        }
      },
      request: (options) => new Promise((resolve, reject) => {
        if (!xmlHttpRequest) {
          reject(new BridgeError("GM.xmlHttpRequest is unavailable."));
          return;
        }
        let settled = false;
        const finish = (callback) => (value) => {
          if (settled) return;
          settled = true;
          callback(value);
        };
        const onload = finish(resolve);
        const onerror = finish(() => reject(new BridgeError("Browser Bridge is offline.")));
        const ontimeout = finish(() => reject(new BridgeError("Browser Bridge timed out.")));
        try {
          const result = xmlHttpRequest.call(source, {
            timeout: 4000,
            ...options,
            onload,
            onerror,
            ontimeout
          });
          if (result && typeof result.then === "function") {
            result.then(onload, onerror);
          }
        } catch (error) {
          onerror(error);
        }
      })
    };
  }

  class BridgeClient {
    constructor(gm) {
      this.gm = gm;
      this.baseURL = null;
      this.instanceID = null;
      this.token = null;
      this.client = null;
      this.discovery = null;
    }

    async discover() {
      const cached = Number(await this.gm.getValue(STORAGE.port, 0));
      const ports = cached
        ? [cached, ...DISCOVERY_PORTS.filter((port) => port !== cached)]
        : DISCOVERY_PORTS;
      for (const port of ports) {
        try {
          const baseURL = `http://127.0.0.1:${port}`;
          const discovery = await this.rawRequest(
            baseURL,
            "GET",
            "/.well-known/ghpr-browser-bridge"
          );
          if (discovery.protocol === "ghpr.browser-bridge/v1") {
            this.baseURL = baseURL;
            this.discovery = discovery;
            this.instanceID = discovery.instance_id;
            const previousInstance = await this.gm.getValue(STORAGE.instance, null);
            if (previousInstance && previousInstance !== discovery.instance_id) {
              await this.gm.setValue(STORAGE.token, null);
            }
            await this.gm.setValue(STORAGE.port, port);
            await this.gm.setValue(STORAGE.instance, discovery.instance_id);
            this.token = await this.gm.getValue(STORAGE.token, null);
            return discovery;
          }
        } catch (_) {
          // Discovery is deliberately silent when ghpr-view is not running.
        }
      }
      this.baseURL = null;
      this.discovery = null;
      this.client = null;
      return null;
    }

    async authenticate() {
      if (!this.baseURL || !this.token) return null;
      try {
        this.client = await this.request("GET", "/api/v1/client");
        return this.client;
      } catch (error) {
        if (error.status === 401) {
          this.token = null;
          this.client = null;
          await this.gm.setValue(STORAGE.token, null);
          return null;
        }
        throw error;
      }
    }

    async pair(onState, requiredScopes = [], returnURL = null) {
      if (!this.baseURL) throw new BridgeError("ghpr-view is not running.");
      onState?.("Requesting native approval…");
      const descriptor = { ...CLIENT, required_scopes: requiredScopes };
      const pairing = await this.request("POST", "/api/v1/pairings", descriptor, false);
      let pairingURL = pairing.pairing_url;
      if (returnURL) {
        const parsedReturn = new URL(returnURL);
        if (parsedReturn.origin === "https://github.com" && parseGitHubPage(parsedReturn)) {
          const url = new URL(pairingURL);
          url.searchParams.set("return", parsedReturn.href);
          pairingURL = url.href;
        }
      }
      this.gm.openInTab(pairingURL);
      const deadline = Date.now() + 5 * 60 * 1000;
      while (Date.now() < deadline) {
        const status = await this.request(
          "GET",
          `/api/v1/pairings/${encodeURIComponent(pairing.request_id)}?secret=${encodeURIComponent(pairing.pairing_secret)}`,
          null,
          false
        );
        onState?.(`Waiting for approval · ${status.state}`);
        if (status.state === "approved" && status.token) {
          this.token = status.token;
          this.client = status.client;
          await this.gm.setValue(STORAGE.token, status.token);
          return status.client;
        }
        if (status.state === "denied" || status.state === "expired") {
          throw new BridgeError(`Pairing was ${status.state}.`);
        }
        await new Promise((resolve) => global.setTimeout(resolve, 1000));
      }
      throw new BridgeError("Pairing approval timed out.");
    }

    async request(
      method,
      path,
      body = null,
      authenticated = true,
      timeoutMs = REQUEST_TIMEOUT_MS
    ) {
      if (!this.baseURL) throw new BridgeError("Browser Bridge is offline.");
      return this.rawRequest(this.baseURL, method, path, body, authenticated, timeoutMs);
    }

    async rawRequest(
      baseURL,
      method,
      path,
      body = null,
      authenticated = false,
      timeoutMs = REQUEST_TIMEOUT_MS
    ) {
      const headers = { Accept: "application/json" };
      if (body !== null) headers["Content-Type"] = "application/json";
      if (authenticated && this.token) headers.Authorization = `Bearer ${this.token}`;
      const response = await this.gm.request({
        method,
        url: `${baseURL}${path}`,
        headers,
        timeout: timeoutMs,
        data: body === null ? undefined : JSON.stringify(body)
      });
      let payload = null;
      try {
        payload = response.responseText ? JSON.parse(response.responseText) : null;
      } catch (_) {
        throw new BridgeError("Browser Bridge returned invalid JSON.", response.status);
      }
      if (response.status < 200 || response.status >= 300) {
        const message = payload?.error?.message || `Browser Bridge returned ${response.status}.`;
        throw new BridgeError(message, response.status, payload);
      }
      return payload;
    }
  }

  function createElement(document, tagName, options = {}, children = []) {
    const element = document.createElement(tagName);
    if (options.className) element.className = options.className;
    if (options.text !== undefined) element.textContent = options.text;
    if (options.title) element.title = options.title;
    if (options.type) element.type = options.type;
    if (options.disabled) element.disabled = true;
    if (options.id) element.id = options.id;
    if (options.dataset) {
      for (const [key, value] of Object.entries(options.dataset)) {
        element.dataset[key] = value;
      }
    }
    if (options.attributes) {
      for (const [key, value] of Object.entries(options.attributes)) {
        element.setAttribute(key, value);
      }
    }
    for (const child of children.flat()) {
      if (child) element.append(child);
    }
    return element;
  }

  function button(document, label, callback, className = "ghpr-button") {
    const element = createElement(document, "button", {
      className,
      text: label,
      type: "button"
    });
    element.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      callback(event);
    });
    return element;
  }

  function toneForVerdict(verdict) {
    if (verdict === "likely_flaky") return "warning";
    if (verdict === "likely_related") return "danger";
    return "analysis";
  }

  function labelForVerdict(verdict) {
    if (verdict === "likely_flaky") return "Likely flaky";
    if (verdict === "likely_related") return "Likely related";
    return "Needs investigation";
  }

  function confidencePercent(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return null;
    return `${Math.round(number <= 1 ? number * 100 : number)}%`;
  }

  function findingSeverityTone(severity) {
    if (severity === "error" || severity === "high") return "danger";
    if (severity === "warning" || severity === "medium") return "warning";
    return "info";
  }

  function isVersionNewer(latest, current) {
    const parse = (value) => {
      const normalized = String(value || "").trim().replace(/^v/i, "");
      const [core, prerelease = ""] = normalized.split("-", 2);
      const parts = core.split(".");
      if (!parts.length || parts.length > 4 || parts.some((part) => !/^\d+$/.test(part))) {
        return null;
      }
      return {
        parts: parts.map(Number),
        prerelease
      };
    };
    const available = parse(latest);
    const installed = parse(current);
    if (!available || !installed) return false;
    const length = Math.max(available.parts.length, installed.parts.length);
    for (let index = 0; index < length; index += 1) {
      const difference = (available.parts[index] || 0) - (installed.parts[index] || 0);
      if (difference !== 0) return difference > 0;
    }
    return !available.prerelease && Boolean(installed.prerelease);
  }

  function isConversationSurface(locationLike) {
    const pathname = locationLike?.pathname || "/";
    return /^\/[^/]+\/[^/]+\/pull\/\d+\/?(?:conversation\/?)?$/.test(pathname);
  }

  function isFilesChangedSurface(locationLike) {
    const pathname = locationLike?.pathname || "/";
    return /^\/[^/]+\/[^/]+\/pull\/\d+\/(?:files|changes)(?:\/(?:[0-9a-f]{7,40}\.\.)?[0-9a-f]{7,40})?\/?$/
      .test(pathname);
  }

  // GitHub serves a historical revision of the PR diff at
  // /pull/<n>/files/<base>..<head> (and /files/<head> for a single commit).
  // Findings reviewed against that head are anchored with the line numbers they
  // were reported on there, not with the ones they were remapped to.
  function filesChangedRevisionRef(locationLike) {
    const pathname = locationLike?.pathname || "/";
    const match = pathname.match(
      /^\/[^/]+\/[^/]+\/pull\/\d+\/(?:files|changes)\/(?:[0-9a-f]{7,40}\.\.)?([0-9a-f]{7,40})\/?$/
    );
    return match ? match[1].toLowerCase() : null;
  }

  function labelForSkillAgent(value) {
    const normalized = String(value || "").trim().toLowerCase().replace(/[-\s]+/g, "_");
    switch (normalized) {
    case "claude_code": return "Claude Code";
    case "codex": return "Codex";
    case "omp": return "OMP";
    case "external": return "External";
    default: return value ? String(value).trim() : null;
    }
  }

  function isChecksSurface(locationLike) {
    const pathname = locationLike?.pathname || "/";
    return /^\/[^/]+\/[^/]+\/pull\/\d+\/checks\/?$/.test(pathname);
  }


  function semanticTargets(document, slot) {
    const selectors = {
      "pr.header.actions": [
        "[data-testid='issue-header'] .gh-header-actions",
        ".gh-header-actions",
        ".gh-header-show"
      ],
      "pr.header.status": [
        "[data-testid='issue-header'] .gh-header-meta",
        ".gh-header-meta"
      ],
      "pr.mergebox.after": [
        "[data-testid='merge-box']",
        "#partial-pull-merging",
        ".mergeability-details"
      ],
      "pr.conversation.after-checks": [
        "[role='region'][aria-label='Checks']",
        "section[aria-label='Checks']",
        ".js-checks-summarized",
        "[data-testid='checks-summary']",
        "#partial-pull-merging"
      ],
      "checks.run.trailing": [
        "[data-testid='check-run-row']",
        ".js-check-run",
        ".CheckRun"
      ],
      "checks.job.trailing": [
        "[data-testid='check-job-row']",
        ".js-check-run",
        ".CheckRun"
      ],
      "files.toolbar.actions": [
        "[data-testid='files-toolbar']",
        "section[data-file-tree-expanded]",
        "#files .pr-toolbar",
        ".diffbar"
      ],
      "files.diff.line-decoration": [
        "table.diff-table",
        "table[data-diff-anchor]"
      ],
      "files.tree.file": [
        "[role='treeitem'][id][aria-label]"
      ]
    };
    const matches = [];
    for (const selector of selectors[slot] || []) {
      for (const element of document.querySelectorAll(selector)) {
        if (!matches.includes(element)) matches.push(element);
      }
      if (matches.length) break;
    }
    return matches;
  }

  function parseWorkflowJobHref(href) {
    if (!href) return null;
    try {
      const url = new URL(href, "https://github.com");
      const match = url.pathname.match(/^\/([^/]+\/[^/]+)\/actions\/runs\/(\d+)\/job\/(\d+)/);
      if (!match) return null;
      return { repository: match[1], runId: match[2], jobId: match[3] };
    } catch (_) {
      return null;
    }
  }

  function workflowJobSubjectKey({ repository, runId, jobId }) {
    return `github:workflow-job:${String(repository).toLowerCase()}:run:${runId}:job:${jobId}`;
  }

  function installStyles(document) {
    if (document.getElementById(STYLE_ID)) return;
    const style = createElement(document, "style", { id: STYLE_ID });
    style.textContent = `
      [${MANAGED_ATTRIBUTE}] {
        --ghpr-purple: #6f6baf;
        --ghpr-purple-strong: #54508f;
        --ghpr-peach: #f2cfb3;
        --ghpr-ink: var(--fgColor-default, #1f2328);
        --ghpr-muted: var(--fgColor-muted, #656d76);
        --ghpr-panel: var(--bgColor-default, #ffffff);
        --ghpr-border: var(--borderColor-default, #d0d7de);
        box-sizing: border-box;
        color: var(--ghpr-ink);
        font: 12px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        text-align: left; white-space: normal;
      }
      [${MANAGED_ATTRIBUTE}] *,
      [${MANAGED_ATTRIBUTE}] *::before,
      [${MANAGED_ATTRIBUTE}] *::after {
        box-sizing: border-box;
      }
      .ghpr-file-tree-badge {
        align-items: center;
        background: var(--ghpr-purple);
        border: 1px solid var(--ghpr-purple-strong);
        border-radius: 999px;
        color: #fff;
        display: inline-flex;
        appearance: none;
        cursor: pointer;
        flex: 0 0 auto;
        font-size: 10px;
        font-weight: 700;
        height: 16px;
        justify-content: center;
        line-height: 1;
        margin-inline-start: 4px;
        min-width: 16px;
        padding: 0 4px;
        font-family: inherit;
      }
      .ghpr-file-tree-badge:focus-visible {
        outline: 2px solid var(--focus-outlineColor, #0969da);
        outline-offset: 2px;
      }
      .ghpr-header-entry {
        align-items: center; display: inline-flex; flex: 0 0 auto;
        height: auto; max-width: calc(100vw - 16px); min-width: 0;
        position: relative; vertical-align: middle; width: auto; z-index: 1;
      }
      .ghpr-header-entry:not(.ghpr-header-floating) { margin-inline: 4px; }
      .ghpr-header-entry.ghpr-header-floating {
        bottom: auto; height: auto; left: auto; margin: 0;
        max-width: calc(100vw - 16px); position: fixed; right: 16px; top: 72px;
        width: auto; z-index: 2147483000;
      }
      .ghpr-header-entry.ghpr-header-floating.ghpr-header-floating-narrow {
        right: 8px; top: 8px;
      }
      .ghpr-header-button {
        appearance: none; background: var(--ghpr-panel); border: 1px solid var(--ghpr-border);
        border-radius: 6px; color: var(--ghpr-ink); cursor: pointer; flex: 0 0 auto; font: inherit;
        font-weight: 650; height: 32px; line-height: 1.35; padding: 5px 9px;
        white-space: nowrap;
      }
      .ghpr-header-button:hover { background: color-mix(in srgb, var(--ghpr-purple) 10%, var(--ghpr-panel)); }
      #ghpr-header-entry > .ghpr-header-menu {
        background: var(--ghpr-panel); border: 1px solid var(--ghpr-border); border-radius: 8px;
        bottom: auto !important; box-shadow: 0 8px 24px rgba(31, 35, 40, .2); box-sizing: border-box;
        color: var(--ghpr-ink); height: auto !important; left: auto; max-height: calc(100dvh - 16px) !important;
        max-width: calc(100vw - 16px) !important; min-width: 0 !important; overflow: auto;
        padding: 9px; position: fixed !important; right: 8px; top: 44px;
        width: min(320px, calc(100vw - 16px)) !important; z-index: 2147483000;
      }
      #ghpr-header-entry > .ghpr-header-menu[hidden] { display: none !important; }
      .ghpr-header-menu {
        background: var(--ghpr-panel); border: 1px solid var(--ghpr-border); border-radius: 8px;
        box-shadow: 0 8px 24px rgba(31, 35, 40, .2); box-sizing: border-box; color: var(--ghpr-ink);
        max-height: calc(100dvh - 16px); max-width: calc(100vw - 16px); overflow: auto; padding: 9px;
      }
      .ghpr-header-menu[hidden] { display: none; }
      .ghpr-header-menu-title { font-size: 13px; font-weight: 750; margin-bottom: 6px; }
      .ghpr-header-menu-summary { color: var(--ghpr-muted); margin: 0 0 8px; }
      .ghpr-header-menu .ghpr-section { margin-top: 8px; }
      .ghpr-header-menu .ghpr-panel-action { min-height: 28px; }
      .ghpr-header-menu summary {
        cursor: pointer; font-weight: 650; min-height: 30px; padding: 6px 8px;
      }
      .ghpr-review-results { border-top: 1px solid var(--ghpr-border); margin: 8px 0 0; padding: 8px 0 0; }
      .ghpr-review-results-body { display: grid; gap: 8px; margin-top: 4px; min-width: 0; }
      .ghpr-review-count { color: var(--ghpr-muted); font-size: 11px; }
      .ghpr-annotations-toggle { align-self: start; }
      .ghpr-annotations-toggle[aria-pressed="true"] {
        background: color-mix(in srgb, var(--ghpr-purple) 14%, var(--ghpr-panel));
        border-color: var(--ghpr-purple);
      }
      .ghpr-update-notice {
        align-items: center; background: color-mix(in srgb, var(--ghpr-peach) 28%, var(--ghpr-panel));
        border: 1px solid color-mix(in srgb, var(--ghpr-peach) 70%, var(--ghpr-border));
        border-radius: 7px; display: flex; flex-wrap: wrap; gap: 8px; justify-content: space-between;
        margin-bottom: 8px; padding: 8px;
      }
      .ghpr-update-copy { min-width: 0; }
      .ghpr-update-copy strong { display: block; }
      .ghpr-update-copy span { color: var(--ghpr-muted); display: block; font-size: 11px; }
      .ghpr-section {
        border-top: 1px solid var(--ghpr-border); margin: 8px 0 0; padding: 8px 0 0;
      }
      .ghpr-section-label {
        color: var(--ghpr-muted); font-size: 10px; font-weight: 700;
        letter-spacing: .08em; margin-bottom: 4px; text-transform: uppercase;
      }
      .ghpr-button, .ghpr-panel-action {
        appearance: none; border: 1px solid var(--ghpr-border); border-radius: 6px;
        background: var(--ghpr-panel); color: var(--ghpr-ink); cursor: pointer;
        font: inherit; line-height: 1.35; margin: 0; min-width: 0; padding: 6px 8px;
      }
      .ghpr-panel-action {
        border: 0; display: block; min-height: 30px; overflow-wrap: anywhere;
        position: static; text-align: left; white-space: normal; width: 100%;
      }
      .ghpr-panel-action:hover:not(:disabled), .ghpr-button:hover:not(:disabled) {
        background: color-mix(in srgb, var(--ghpr-purple) 10%, var(--ghpr-panel));
      }
      .ghpr-button-primary { background: var(--ghpr-purple); border-color: var(--ghpr-purple); color: white; }
      .ghpr-panel-action:disabled, .ghpr-button:disabled,
      .ghpr-badge.ghpr-busy,
      [aria-disabled="true"].ghpr-panel-action,
      [aria-disabled="true"].ghpr-button {
        background: rgba(110, 118, 129, .12);
        border-color: var(--ghpr-border);
        color: color-mix(in srgb, var(--ghpr-ink) 45%, transparent);
        cursor: not-allowed;
      }
      .ghpr-action-row { align-items: center; display: flex; flex-wrap: wrap; gap: 6px; min-width: 0; }
      .ghpr-badge {
        border: 1px solid currentColor; border-radius: 999px; display: inline-flex;
        font-size: 11px; font-weight: 650; line-height: 20px; padding: 0 7px; white-space: nowrap;
      }
      .ghpr-tone-warning { color: #9a6700; background: rgba(242, 207, 179, .25); }
      .ghpr-tone-danger { color: #cf222e; background: rgba(255, 129, 130, .12); }
      .ghpr-tone-success { color: #1a7f37; background: rgba(63, 185, 80, .12); }
      .ghpr-tone-analysis, .ghpr-tone-info { color: var(--ghpr-purple-strong); background: rgba(111, 107, 175, .12); }
      .ghpr-card {
        border: 1px solid var(--ghpr-border); border-left: 3px solid var(--ghpr-purple);
        border-radius: 8px; background: var(--ghpr-panel); margin: 10px 0; padding: 12px;
      }
      .ghpr-card-head { align-items: center; display: flex; gap: 8px; justify-content: space-between; }
      .ghpr-card-title { font-weight: 750; }
      .ghpr-card-summary { color: var(--ghpr-muted); margin: 7px 0; }
      .ghpr-finding-tools { align-items: center; display: flex; flex-wrap: wrap; gap: 6px; }
      .ghpr-fallback { max-height: 160px; overflow: auto; }
      .ghpr-error { color: #cf222e; font-size: 11px; margin-top: 5px; }
      @media (max-width: 720px) {
        .ghpr-panel-action, .ghpr-header-menu summary { min-height: 40px; padding: 10px; }
        .ghpr-action-row { align-items: stretch; flex-direction: column; }
        .ghpr-action-row .ghpr-button { min-height: 40px; width: 100%; }
      }
    `;
    (document.head || document.documentElement).append(style);
  }

  class GhprGitHubApp {
    constructor({ window, document, gm }) {
      this.window = window;
      this.document = document;
      this.gm = gm;
      this.bridge = new BridgeClient(gm);
      this.page = null;
      this.snapshot = null;
      this.timer = null;
      this.observer = null;
      this.refreshing = false;
      this.stopped = false;
      this.navigationKey = null;
      this.menuOpen = false;
      this.reviewResultsOpen = false;
      this.showCodeAnnotations = false;
      this.expansionKey = null;
      this.headerMenu = null;
      this.pendingSkillRuns = new Set();
      this.surfaceRegistry = null;
      this.drawerHost = null;
      this.modalHost = null;
      this.filesFindingPanelMount = null;
      this.selectedFilesFindingID = null;
      this.selectedFileFindingID = null;
      this._pendingFileFindingScrollV2 = null;
      this.pendingSubjectRuns = new Set();
      this.pendingExplainCIV2 = false;
      this._navigatedFindingIDV2 = null;
      this._findingNavigationTimersV2 = new Map();
      this.navigationTimerV2 = null;
      this.observerRoot = null;
      this.scheduleNavigationRefresh = null;
      this.loadError = null;
    }

    async start() {
      installStyles(this.document);
      this.gm.registerMenuCommand("Open in ghpr", () => this.openApp());
      this.gm.registerMenuCommand("Connect ghpr", async () => {
        const client = await this.bridge.pair();
        if (client) await this.refreshSafely();
      });
      this.gm.registerMenuCommand("Analyze current PR", () => {
        if (this.page?.type !== "pull_request") return;
        this.startPRReviewV2();
      });
      this.observeNavigation();
      await this.refresh();
      return this;
    }

    stop() {
      this.stopped = true;
      if (this.timer) this.window.clearTimeout(this.timer);
      if (this.navigationTimerV2) this.window.clearTimeout(this.navigationTimerV2);
      if (this.onViewportChange) {
        this.window.removeEventListener("resize", this.onViewportChange);
        this.onViewportChange = null;
      }
      this.observer?.disconnect();
      this.observerRoot = null;
    }

    observeNavigation() {
      const schedule = () => {
        if (this.navigationTimerV2) return;
        this.navigationTimerV2 = this.window.setTimeout(() => {
          this.navigationTimerV2 = null;
          const key = `${this.window.location.pathname}${this.window.location.search}`;
          if (key !== this.navigationKey) {
            this.refreshSafely();
          } else {
            this.render();
          }
        }, 150);
      };
      this.scheduleNavigationRefresh = schedule;
      this.observeActiveSurfaceRoot(schedule);
      this.window.addEventListener("popstate", schedule);
      this.window.addEventListener("turbo:load", schedule);
      this.window.addEventListener("turbo:render", schedule);
      this.window.addEventListener("ghpr:navigation", schedule);
      this.onViewportChange = () => {
        if (this.stopped) return;
        this.renderHeaderEntry();
      };
      this.window.addEventListener("resize", this.onViewportChange);
    }

    isManagedMutationV2(mutation) {
      const isManagedElement = (node) =>
        node?.nodeType === 1 && (
          node.matches?.(`[${MANAGED_ATTRIBUTE}], [data-ghpr-surface]`) ||
          node.closest?.(`[${MANAGED_ATTRIBUTE}], [data-ghpr-surface]`)
        );
      if (isManagedElement(mutation.target)) return true;
      const changedNodes = [
        ...(mutation.addedNodes || []),
        ...(mutation.removedNodes || [])
      ];
      return changedNodes.length > 0 && changedNodes.every((node) =>
        isManagedElement(node) || isManagedElement(node?.parentElement)
      );
    }

    observeActiveSurfaceRoot(schedule = this.scheduleNavigationRefresh) {
      if (!schedule) return;
      const root = this.document.querySelector("main") || this.document.body;
      if (!root || root === this.observerRoot) return;
      this.observer?.disconnect();
      this.observer = new this.window.MutationObserver((mutations) => {
        if (mutations.length && mutations.every((mutation) => this.isManagedMutationV2(mutation))) {
          return;
        }
        schedule();
      });
      this.observer.observe(root, { childList: true, subtree: true });
      this.observerRoot = root;
    }

    async refresh() {
      if (this.refreshing || this.stopped) return;
      this.refreshing = true;
      this.navigationKey = `${this.window.location.pathname}${this.window.location.search}`;
      try {
        this.page = parseGitHubPage(this.window.location);
        if (!this.page) {
          this.cleanup();
          return;
        }
        const discovery = await this.bridge.discover();
        if (!discovery) {
          this.cleanup();
          return;
        }
        const client = await this.bridge.authenticate();
        if (!client) {
          this.renderConnect();
          return;
        }
        const query = this.page.type === "pull_request"
          ? `repository=${encodeURIComponent(this.page.repository)}&number=${this.page.pr_number}`
          : `repository=${encodeURIComponent(this.page.repository)}&run_id=${this.page.workflow_run_id}`;
        this.snapshot = await this.bridge.request(
          "GET",
          `/api/v1/page?${query}`,
          null,
          true,
          SNAPSHOT_TIMEOUT_MS
        );
        this.loadError = null;
        this.render();
      } catch (error) {
        if (error.status === 401) {
          this.renderConnect();
        } else {
          this.loadError = error.message;
          this.render();
        }
      } finally {
        this.refreshing = false;
        this.observeActiveSurfaceRoot();
        this.scheduleNextRefresh();
      }
    }

    // Timer, navigation, and observer callbacks cannot await refresh(), so a
    // throw outside its own catch — including one from its finally block —
    // would otherwise stop every later poll with no diagnostic at all.
    refreshSafely() {
      return this.refresh().catch((error) => {
        this.window.console?.error?.("[ghpr] refresh failed:", error);
        this.refreshing = false;
        try {
          this.scheduleNextRefresh();
        } catch (_) {
          // Rescheduling must never mask the failure it is recovering from.
        }
      });
    }

    scheduleNextRefresh() {
      if (this.stopped) return;
      if (this.timer) this.window.clearTimeout(this.timer);
      const active = this.snapshot?.runs?.some((run) =>
        run.status === "queued" || run.status === "running"
      );
      this.timer = this.window.setTimeout(
        () => this.refreshSafely(),
        active ? POLL_ACTIVE_MS : POLL_IDLE_MS
      );
    }

    cleanupSurfaceV2() {
      this.drawerHost?.close();
      this.modalHost?.close();
      this.filesFindingPanelMount?.destroy();
      this.filesFindingPanelMount = null;
      this.selectedFilesFindingID = null;
      this.surfaceRegistry?.destroyAll();
      if (this._highlightTimer) {
        this.window.clearTimeout(this._highlightTimer);
        this._highlightTimer = null;
      }
      for (const timer of this._findingNavigationTimersV2.values()) {
        this.window.clearTimeout(timer);
      }
      this._findingNavigationTimersV2.clear();
    }

    cleanup(clearSnapshot = true) {
      this.document.getElementById(HEADER_ENTRY_ID)?.remove();
      for (const node of this.document.querySelectorAll(`[${MANAGED_ATTRIBUTE}]`)) {
        node.remove();
      }
      this.cleanupSurfaceV2();
      if (clearSnapshot) this.snapshot = null;
      this.headerMenu = null;
      this.menuOpen = false;
    }
    viewportBox() {
      return {
        width: this.window.innerWidth || this.document.documentElement?.clientWidth || 0,
        height: this.window.innerHeight || this.document.documentElement?.clientHeight || 0
      };
    }

    usableRect(rect) {
      return Boolean(rect) && Number.isFinite(rect.width) && Number.isFinite(rect.height) &&
        (rect.width > 0 || rect.height > 0 || rect.right > 0 || rect.bottom > 0);
    }

    // GitHub's narrow page header uses min-width: max-content and moves actions
    // above the title. A button mounted there sits past the viewport edge.
    hostOverflowsViewport(host) {
      const box = this.viewportBox();
      if (!box.width || typeof host?.getBoundingClientRect !== "function") return false;
      const rect = host.getBoundingClientRect();
      if (!this.usableRect(rect)) return false;
      if (rect.right > box.width + 1 || rect.left < -1) return true;
      return (host.scrollWidth || 0) > (host.clientWidth || 0) + 8 && rect.width >= box.width - 8;
    }

    buttonClipped(button) {
      const box = this.viewportBox();
      if (!box.width || typeof button?.getBoundingClientRect !== "function") return false;
      const rect = button.getBoundingClientRect();
      if (!this.usableRect(rect)) return false;
      return rect.left < 4 || rect.right > box.width - 4 || rect.width < 20;
    }

    fixedPositionTrapped(node) {
      if (typeof this.window.getComputedStyle !== "function") return false;
      let current = node?.parentElement;
      while (current && current !== this.document.documentElement && current !== this.document.body) {
        let style;
        try {
          style = this.window.getComputedStyle(current);
        } catch (_) {
          return false;
        }
        if (!style) return false;
        const transform = style.transform || "none";
        const filter = style.filter || "none";
        const contain = style.contain || "";
        const willChange = style.willChange || "";
        if ((transform && transform !== "none") ||
            (filter && filter !== "none") ||
            /paint|layout|strict|content/.test(contain) ||
            /transform|filter|contain/.test(willChange)) {
          return true;
        }
        current = current.parentElement;
      }
      return false;
    }

    clearHeaderMenuPlacement(menu) {
      if (!menu) return;
      for (const property of [
        "position", "left", "right", "top", "bottom", "width", "height",
        "max-height", "max-width", "overflow", "z-index"
      ]) {
        menu.style.removeProperty(property);
      }
      const entry = this.document.getElementById(HEADER_ENTRY_ID);
      if (entry && menu.parentElement !== entry) entry.append(menu);
    }

    // Host CSS can set both left and right on an absolutely positioned menu,
    // which stretches it into the blank panel in the screenshot. Pin an
    // explicit viewport box instead.
    placeHeaderMenu(menu) {
      if (!menu) return;
      if (!this.menuOpen) {
        this.clearHeaderMenuPlacement(menu);
        return;
      }
      const entry = this.document.getElementById(HEADER_ENTRY_ID);
      const button = entry?.querySelector(".ghpr-header-button");
      if (entry && this.fixedPositionTrapped(entry) && menu.parentElement !== this.document.body) {
        this.document.body.append(menu);
      }
      const box = this.viewportBox();
      const rect = typeof button?.getBoundingClientRect === "function"
        ? button.getBoundingClientRect()
        : null;
      if (!box.width || !box.height || !this.usableRect(rect)) return;
      const margin = 8;
      const width = Math.min(320, Math.max(180, box.width - margin * 2));
      let left = Math.max(margin, Math.min(rect.right - width, box.width - margin - width));
      let top = rect.bottom + 6;
      if (top + 160 > box.height - margin) {
        top = Math.max(margin, rect.top - 6 - Math.min(360, box.height - margin * 2));
      }
      const maxHeight = Math.max(120, box.height - top - margin);
      const set = (name, value) => menu.style.setProperty(name, value, "important");
      set("position", "fixed");
      set("left", `${Math.round(left)}px`);
      set("right", "auto");
      set("top", `${Math.round(top)}px`);
      set("bottom", "auto");
      set("width", `${Math.round(width)}px`);
      set("height", "auto");
      set("max-width", `${Math.round(box.width - margin * 2)}px`);
      set("max-height", `${Math.round(maxHeight)}px`);
      set("overflow", "auto");
      set("z-index", "2147483000");
    }

    headerMount() {
      const box = this.viewportBox();
      const narrow = box.width > 0 && box.width <= 1011;
      const selectors = [
        "[data-testid='issue-header'] .gh-header-actions",
        "[data-testid='issue-header'] .gh-header-show",
        ".gh-header-actions",
        ".gh-header-show"
      ];
      // Current GitHub puts PR actions in PH_Actions and, below 1012px, lifts
      // that row above the title with min-width: max-content. Skip it then.
      if (!narrow) selectors.push("[data-component='PH_Actions']");
      for (const selector of selectors) {
        const host = this.document.querySelector(selector);
        if (!host || host.closest?.("[hidden]") || host.classList?.contains("d-none")) continue;
        if (narrow && this.hostOverflowsViewport(host)) continue;
        return { host, before: null, floating: false, narrow: false };
      }

      const profileAnchor = (host) => {
        const explicit = host.querySelector(
          ".AppHeader-user, [data-testid='user-menu-button'], " +
          "[aria-label*='user navigation' i], [aria-label*='profile' i]"
        );
        if (explicit) return explicit;
        const avatar = host.querySelector("img.avatar");
        return avatar?.closest("button, details, a") || avatar;
      };
      const globalActions = this.document.querySelector(
        ".AppHeader-globalBar-end, [data-testid='app-header-global-bar-end'], " +
        "[data-testid='top-nav-right']"
      );
      if (globalActions && !(narrow && this.hostOverflowsViewport(globalActions))) {
        return {
          host: globalActions,
          before: profileAnchor(globalActions),
          floating: false,
          narrow: false
        };
      }

      const pageHeader = this.document.querySelector("header");
      const profile = pageHeader ? profileAnchor(pageHeader) : null;
      if (profile?.parentElement && !(narrow && this.hostOverflowsViewport(profile.parentElement))) {
        return { host: profile.parentElement, before: profile, floating: false, narrow: false };
      }
      return { host: this.document.body, before: null, floating: true, narrow };
    }

    renderHeaderEntry() {
      let mount = this.headerMount();
      if (!mount.host) return null;

      let entry = this.document.getElementById(HEADER_ENTRY_ID);
      if (!entry) {
        entry = createElement(this.document, "span", {
          id: HEADER_ENTRY_ID,
          className: "ghpr-header-entry",
          attributes: {
            [MANAGED_ATTRIBUTE]: "",
            "aria-label": "ghpr GitHub tools"
          }
        });
        const menu = createElement(this.document, "div", {
          className: "ghpr-header-menu",
          attributes: { role: "menu", hidden: "", [MANAGED_ATTRIBUTE]: "" }
        });
        const toggle = button(this.document, "ghpr ▾", () => {
          this.menuOpen = !this.menuOpen;
          this.syncHeaderMenu(
            this.headerMenu || entry.querySelector(".ghpr-header-menu"),
            { rebuild: true }
          );
        }, "ghpr-header-button");
        toggle.setAttribute("aria-haspopup", "menu");
        toggle.setAttribute("aria-expanded", "false");
        entry.append(toggle, menu);
      }
      const applyMount = (next) => {
        entry.classList.toggle("ghpr-header-floating", Boolean(next.floating));
        entry.classList.toggle(
          "ghpr-header-floating-narrow",
          Boolean(next.floating && next.narrow)
        );
        if (next.before) {
          if (entry.parentElement !== next.host || entry.nextElementSibling !== next.before) {
            next.host.insertBefore(entry, next.before);
          }
        } else if (entry.parentElement !== next.host) {
          next.host.append(entry);
        }
      };
      applyMount(mount);
      if (!mount.floating && this.buttonClipped(entry.querySelector(".ghpr-header-button"))) {
        mount = { host: this.document.body, before: null, floating: true, narrow: true };
        applyMount(mount);
      }
      const menu = this.headerMenu?.isConnected
        ? this.headerMenu
        : entry.querySelector(".ghpr-header-menu");
      this.headerMenu = menu;
      this.syncHeaderMenu(menu);
      return menu;
    }

    // The entry is the only thing this userscript mounts on its own. The menu
    // body is built while the menu is open and is never rebuilt under the
    // user's focus, so polling cannot move the view or overwrite a draft.
    syncHeaderMenu(menu, { rebuild = false } = {}) {
      if (!menu) return;
      const entry = this.document.getElementById(HEADER_ENTRY_ID);
      const toggle = entry?.querySelector(".ghpr-header-button") ||
        menu.parentElement?.querySelector(".ghpr-header-button");
      menu.hidden = !this.menuOpen;
      toggle?.setAttribute("aria-expanded", String(this.menuOpen));
      if (!this.menuOpen) {
        this.placeHeaderMenu(menu);
        return;
      }
      const active = this.document.activeElement;
      if (rebuild || !active || !menu.contains(active)) this.renderHeaderMenu(menu);
      this.placeHeaderMenu(menu);
    }

    // Connection state with Connect/Update/Retry, the existing manual actions,
    // the comment-shortcut entry point, the collapsed Review results section,
    // and the extension fallback for contributions with no native anchor.
    renderHeaderMenu(menu) {
      menu.replaceChildren();
      menu.append(createElement(this.document, "div", {
        className: "ghpr-header-menu-title",
        text: "ghpr"
      }));
      const updateNotice = this.renderUpdateNotice();
      if (updateNotice) menu.append(updateNotice);
      if (this.loadError) {
        menu.append(createElement(this.document, "p", {
          className: "ghpr-error",
          text: this.loadError
        }));
      }
      if (this.actionError) {
        menu.append(createElement(this.document, "p", {
          className: "ghpr-error",
          text: this.actionError
        }));
      }

      if (!this.snapshot) {
        menu.append(createElement(this.document, "p", {
          className: "ghpr-header-menu-summary",
          text: "Connect this userscript to the local ghpr Browser Bridge."
        }));
        menu.append(this.connectAction());
        if (this.loadError) {
          menu.append(button(this.document, "Retry", () => this.refreshSafely(), "ghpr-button"));
        }
        return;
      }

      const analysis = this.snapshot.analyses[0] || null;
      menu.append(createElement(this.document, "p", {
        className: "ghpr-header-menu-summary",
        text: analysis
          ? `${labelForVerdict(analysis.verdict)} · ${analysis.confidence} confidence`
          : "Local PR operations"
      }));

      const activeRun = (this.snapshot.runs || []).find((run) =>
        run.status === "queued" || run.status === "running"
      );
      if (activeRun && this.hasScope("detail:open")) {
        menu.append(this.menuAction("View live log", () =>
          this.invokeAction({ kind: "open_detail", run_id: activeRun.id })
        ));
      }

      if (this.page?.type === "pull_request") {
        const actions = this.menuSection("Actions");
        if (this.hasScope("skill:run")) {
          actions.append(
            this.runAction("Explain CI Failure", {
              kind: "run_skill",
              skill_id: "ci.failure.explain"
            }),
            this.runAction("Classify Flaky", {
              kind: "run_skill",
              skill_id: "ci.failure.classify_flaky"
            })
          );
          const skills = this.renderRunnableSkills();
          if (skills) actions.append(skills);
        } else {
          actions.append(this.permissionPrompt(
            "Run Skills",
            "skill:run",
            "Analysis actions are off for this client."
          ));
        }
        const failedCheckCount = Number(this.snapshot.pull_request?.check_failure_count || 0);
        if (failedCheckCount > 0) {
          actions.append(this.menuAction(
            `Re-run ${failedCheckCount} failed ${failedCheckCount === 1 ? "job" : "jobs"}`,
            () => this.rerunFailedChecksV2()
          ));
        }
        if (actions.children.length) menu.append(actions);

        const tags = this.menuSection("Tags");
        if (this.hasScope("tag:write")) {
          for (const [value, label] of [
            ["flaky", "Flaky"],
            ["not_flaky", "Not flaky"],
            ["needs_investigation", "Needs investigation"]
          ]) {
            const selected = this.snapshot.tags.includes(value);
            tags.append(this.menuAction(`${selected ? "✓ " : ""}${label}`, () =>
              this.invokeAction({
                kind: selected ? "remove_tag" : "set_tag",
                tag: value
              })
            ));
          }
        } else {
          tags.append(this.permissionPrompt(
            "Edit local ghpr tags",
            "tag:write",
            "Tag changes are off for this client."
          ));
        }
        if (tags.children.length) menu.append(tags);

        if (analysis && this.hasScope("detail:open")) {
          menu.append(this.menuAction("Open Full Analysis", () =>
            this.invokeAction({ kind: "open_detail", analysis_id: analysis.id })
          ));
        }
      }

      if (this.hasScope("app:open")) {
        menu.append(this.menuAction("Open in ghpr", () =>
          this.invokeAction({ kind: "open_app" })
        ));
      } else {
        menu.append(this.permissionPrompt(
          "Open in ghpr",
          "app:open",
          "Open ghpr-view permission is required."
        ));
      }

      this.renderCommentShortcutSection(menu);
      this.renderReviewResultsSection(menu);
      this.renderContributions(menu);
    }

    connectAction() {
      const connect = button(this.document, "Connect ghpr", async () => {
        connect.disabled = true;
        connect.textContent = "Waiting for approval…";
        try {
          await this.bridge.pair((message) => {
            connect.textContent = message;
          });
          await this.refresh();
        } catch (error) {
          connect.disabled = false;
          connect.textContent = "Connect ghpr";
          connect.title = error.message;
        }
      }, "ghpr-button ghpr-button-primary");
      connect.setAttribute("aria-label", "Connect ghpr for GitHub");
      return connect;
    }

    // Entry point for the comment shortcuts the configured app exposes as
    // `snapshot.comment_shortcuts` ([{ id, display_name, template, ... }]).
    // Another owner implements that data path (the `prepare_comment_shortcut`
    // BrowserAction provider); until the snapshot carries shortcuts this hook
    // renders nothing at all, so the menu never grows an empty section. This
    // hook only ever asks the app to prepare a draft — it never posts a
    // comment and never writes into a composer by itself.
    renderCommentShortcutSection(menu, context = this.page) {
      const shortcuts = Array.isArray(this.snapshot?.comment_shortcuts)
        ? this.snapshot.comment_shortcuts.filter((shortcut) =>
            shortcut && (shortcut.enabled !== false) && (shortcut.id || shortcut.display_name)
          )
        : [];
      if (!shortcuts.length) return null;
      const section = this.menuSection("Comment shortcuts");
      for (const shortcut of shortcuts) {
        section.append(this.menuAction(
          shortcut.display_name || shortcut.id,
          () => this.invokeAction({
            kind: "prepare_comment_shortcut",
            shortcut_id: shortcut.id,
            page: context
          })
        ));
      }
      menu.append(section);
      return section;
    }

    // Review results stay collapsed until the user asks for them, in this PR
    // only, and the code annotations the panel can show are opt-in per PR.
    renderReviewResultsSection(menu) {
      if (this.page?.type !== "pull_request") return;
      const section = this.menuSection();
      const body = createElement(this.document, "div", { className: "ghpr-review-results-body" });
      const toggle = button(this.document, "", () => {
        this.reviewResultsOpen = !this.reviewResultsOpen;
        if (this.reviewResultsOpen) this.fillReviewResults(body);
        else body.replaceChildren();
        this.syncReviewResultsToggle(toggle, body);
      }, "ghpr-panel-action ghpr-review-results-toggle");
      section.append(toggle, body);
      if (this.reviewResultsOpen) this.fillReviewResults(body);
      this.syncReviewResultsToggle(toggle, body);
      menu.append(section);
    }

    syncReviewResultsToggle(toggle, body) {
      const findings = this.findingsForSurfaceV2();
      const count = findings.length
        ? ` · ${findings.length} ${findings.length === 1 ? "finding" : "findings"}`
        : "";
      toggle.textContent = `${this.reviewResultsOpen ? "⌄" : "›"} Review results${count}`;
      toggle.setAttribute("aria-expanded", String(this.reviewResultsOpen));
      body.hidden = !this.reviewResultsOpen;
    }

    fillReviewResults(body) {
      const SR = global.GhprSurfaceRenderers;
      const findings = this.findingsForSurfaceV2();
      const review = this.latestCodeReview();
      const reviewedSHA = review?.head_sha ||
        findings.map((finding) => finding.reviewed_head_sha).find(Boolean) ||
        "";
      body.replaceChildren();
      if (reviewedSHA) {
        body.append(createElement(this.document, "p", {
          className: "ghpr-review-count",
          text: `Reviewed revision ${reviewedSHA.slice(0, 7)}`
        }));
      }
      if (review?.overview_markdown) {
        body.append(createElement(this.document, "p", {
          className: "ghpr-review-count",
          text: review.overview_markdown
        }));
      }
      if (SR && findings.length) {
        for (const finding of findings) {
          body.append(SR.renderSurface(
            this.document,
            "review_finding",
            this.buildReviewFindingModelV2(finding, { expanded: true, openInFiles: true })
          ));
        }
      } else if (!review?.overview_markdown) {
        body.append(createElement(this.document, "p", {
          className: "ghpr-review-count",
          text: "No review results yet."
        }));
      }
      if (isFilesChangedSurface(this.window.location)) {
        body.append(this.annotationsToggle());
      }
    }

    annotationsToggle() {
      const toggle = button(this.document, "", () => {
        this.showCodeAnnotations = !this.showCodeAnnotations;
        this.renderFindingAnnotations();
        this.syncAnnotationsToggle(toggle);
      }, "ghpr-panel-action ghpr-annotations-toggle");
      this.syncAnnotationsToggle(toggle);
      return toggle;
    }

    syncAnnotationsToggle(toggle) {
      toggle.textContent = `Code annotations: ${this.showCodeAnnotations ? "on" : "off"}`;
      toggle.setAttribute("aria-pressed", String(this.showCodeAnnotations));
      toggle.setAttribute("aria-label", this.showCodeAnnotations
        ? "Hide ghpr code annotations in this diff"
        : "Show ghpr code annotations in this diff");
    }

    // Expand state belongs to the PR the user is looking at: a snapshot
    // refresh keeps it, and any move to another PR (including GitHub's SPA
    // navigation) collapses the menu, the results panel and the annotations.
    syncExpansionState() {
      const key = this.page ? this.page.key : this.window.location.pathname;
      if (key === this.expansionKey) return;
      this.expansionKey = key;
      this.menuOpen = false;
      this.reviewResultsOpen = false;
      this.showCodeAnnotations = false;
      this.actionError = null;
    }

    render() {
      this.syncExpansionState();
      this.renderHeaderEntry();
      const SR = global.GhprSurfaceRenderers;
      if (!SR) return;
      SR.installSurfaceStyles(this.document);
      this.renderFindingAnnotations();
      if (!this.snapshot) return;
      // An explicit ghpr_finding deep link is the one annotation that always
      // resolves, even while the code annotations toggle is off.
      if (isFilesChangedSurface(this.window.location)) {
        this.handleFindingNavigationV2(SR, this.anchoredFindingsForSurfaceV2());
      }
    }

    // Unpaired and unauthorized pages keep the same single entry; the menu
    // itself carries the Connect action and the last load error with Retry.
    renderConnect() {
      this.snapshot = null;
      this.loadError = null;
      this.render();
    }

    // Findings are only painted onto the GitHub diff while the user asks for
    // it; switching them off (or switching PR) removes every annotation this
    // userscript added and leaves the GitHub DOM as it found it.
    renderFindingAnnotations() {
      const SR = global.GhprSurfaceRenderers;
      if (!SR) return;
      if (!this.surfaceRegistry) {
        this.surfaceRegistry = new SR.SurfaceRegistry({ document: this.document });
      }
      const anchored = this.snapshot ? this.anchoredFindingsForSurfaceV2() : [];
      if (!this.showCodeAnnotations || !this.snapshot || !anchored.length ||
          !isFilesChangedSurface(this.window.location)) {
        this.surfaceRegistry.destroyAll();
        for (const badge of this.document.querySelectorAll("[data-ghpr-file-tree-badge]")) {
          badge.remove();
        }
        this.filesFindingPanelMount?.destroy();
        this.filesFindingPanelMount = null;
        return;
      }
      const activeKeys = [];
      const mount = (surfaceId, host, model, viewType, opts) => {
        if (!host) return null;
        const content = this.surfaceRegistry.mount(surfaceId, host, model, viewType, opts);
        activeKeys.push(`${surfaceId}::${opts.instanceKey || "default"}`);
        return content;
      };
      this.renderFilesTreeBadgesV2();
      this.renderFilesDiffLineSurfacesV2(SR, mount);
      this.renderFilesFileHeadersV2(SR, mount);
      this.surfaceRegistry.unmountStale(activeKeys);
    }

    explainCIFailureV2(SR) {
      const subject = this.snapshot?.current_revision_subject;
      if (!this.modalHost || subject?.type !== "pull_request_revision") {
        this.renderTransientError("The latest pull request revision is not available yet.");
        return;
      }
      const skill = (this.snapshot?.skills || []).find(
        (candidate) => candidate.id === "ci.failure.explain"
      );
      const latestRun = [...(this.snapshot?.runs || [])]
        .filter((run) => run.skill_id === "ci.failure.explain" && run.agent)
        .sort((left, right) =>
          String(right.completed_at || right.started_at || right.created_at || "")
            .localeCompare(String(left.completed_at || left.started_at || left.created_at || ""))
        )[0];
      const runtimes = this.runtimeOptionsV2(skill);
      const selectedRuntime = runtimes.some((runtime) => runtime.id === latestRun?.agent)
        ? latestRun.agent
        : skill?.default_agent || runtimes[0]?.id;
      const content = SR.renderSurface(this.document, "review_launch_dialog", {
        title: "Explain failed checks",
        subtitle: "Choose the coding agent runtime and model before ghpr analyzes the current failures.",
        repository: subject.repository,
        number: subject.pr_number,
        baseSHA: subject.base_sha,
        headSHA: subject.head_sha,
        runtimes,
        selectedRuntime,
        sectionTitle: "Run failure explanation with ghpr",
        sectionCopy: "ghpr gathers the failed-check evidence and runs the selected coding agent locally.",
        startLabel: "Explain failure",
        startActionID: "start-explain-failure",
        showImport: false,
        onStart: async (selection) => {
          const started = await this.runCIFailureExplanationV2(SR, selection);
          if (started) this.modalHost?.close();
          return started;
        }
      });
      this.modalHost.open(content, {
        triggerEl: this.document.activeElement,
        ariaLabel: "Explain failed checks"
      });
    }

    rerunFailedChecksV2() {
      const SR = global.GhprSurfaceRenderers;
      if (!SR) {
        this.renderTransientError("The failed-check action dialog is unavailable.");
        return;
      }
      if (!this.modalHost) this.modalHost = new SR.ModalHost({ document: this.document });
      const canExplain = this.hasScope("skill:run") &&
        !this.pendingExplainCIV2 &&
        !this.activeRunForSkill("ci.failure.explain");
      const content = SR.renderFailedChecksRerunDialog(this.document, {
        canExplain,
        onExplain: canExplain
          ? () => {
              this.modalHost?.close();
              this.explainCIFailureV2(SR);
            }
          : undefined,
        onRerun: () => {
          this.modalHost?.close();
          this.invokeConfirmedAction({ kind: "rerun_failed_jobs" });
        }
      });
      this.modalHost.open(content, {
        triggerEl: this.document.activeElement,
        ariaLabel: "Re-run failed jobs"
      });
    }


    async runCIFailureExplanationV2(SR, runtimeSelection) {
      if (this.pendingExplainCIV2 || this.activeRunForSkill("ci.failure.explain")) return false;
      this.pendingExplainCIV2 = true;
      try {
        const action = {
          kind: "run_skill",
          skill_id: "ci.failure.explain"
        };
        if (runtimeSelection?.agent) action.agent = runtimeSelection.agent;
        if (runtimeSelection?.model) action.model = runtimeSelection.model;
        if (runtimeSelection?.reasoningEffort) {
          action.reasoning_effort = runtimeSelection.reasoningEffort;
        }
        const response = await this.bridge.request("POST", "/api/v1/actions", {
          action,
          page: this.page,
          confirmed: false
        });
        this.openResponseURL(response);
        await this.refresh();
        return true;
      } catch (error) {
        this.renderTransientError(error.message);
        return false;
      } finally {
        this.pendingExplainCIV2 = false;
      }
    }

    findingsForSurfaceV2() {
      return this.findingsForSnapshot(false);
    }

    // On /pull/<n>/files/<sha> the diff is the reviewed revision itself, so
    // findings reviewed against that commit are anchored with the lines they
    // were reported on instead of the lines they were remapped to.
    anchoredFindingsForSurfaceV2() {
      const revisionRef = filesChangedRevisionRef(this.window.location);
      const findings = this.findingsForSurfaceV2();
      if (!revisionRef) return findings;
      return findings.map((finding) => {
        const reviewed = String(finding.reviewed_head_sha || "").toLowerCase();
        if (!reviewed || !reviewed.startsWith(revisionRef)) return finding;
        return {
          ...finding,
          file: finding.original_file || finding.file,
          side: finding.original_side || finding.side,
          start_line: finding.original_start_line || finding.start_line,
          end_line: finding.original_end_line || finding.end_line,
          line: finding.original_end_line || finding.line,
          reviewed_revision_view: true
        };
      });
    }

    reviewedRevisionFilesURLV2(finding) {
      const repository = this.snapshot?.page?.repository || this.page?.repository;
      const prNumber = this.snapshot?.page?.pr_number || this.page?.pr_number;
      const sha = String(finding?.reviewed_head_sha || "");
      const baseSHA = String(finding?.reviewed_base_sha || "");
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository || "")) return null;
      if (!Number.isInteger(Number(prNumber)) || Number(prNumber) <= 0) return null;
      if (!/^[0-9a-f]{40}$/i.test(sha)) return null;
      // The two-dot range reproduces the whole PR diff as it stood at the
      // reviewed head; a bare head only shows that single commit.
      const revision = /^[0-9a-f]{40}$/i.test(baseSHA) ? `${baseSHA}..${sha}` : sha;
      const url = new URL(`https://github.com/${repository}/pull/${prNumber}/files/${revision}`);
      url.searchParams.set("ghpr_finding", finding.id);
      const file = finding.original_file || finding.file;
      if (file) url.searchParams.set("path", file);
      const line = finding.original_end_line || finding.end_line || finding.line;
      if (line) {
        url.searchParams.set("line", String(line));
        url.hash = `L${line}`;
      }
      return url.href;
    }

    lifecycleChipV2(finding) {
      if (finding.reviewed_revision_view) {
        return { lifecycleLabel: "Reviewed revision", lifecycleTone: "attention" };
      }
      switch (finding.lifecycle) {
        case "outdated":
        case "unavailable":
          return { lifecycleLabel: "Outdated", lifecycleTone: "danger" };
        case "remapped":
          return { lifecycleLabel: "Moved", lifecycleTone: "attention" };
        default:
          return { lifecycleLabel: undefined, lifecycleTone: undefined };
      }
    }

    buildDiffSnippetModelV2(finding) {
      if (finding.snippet?.lines?.length) return finding.snippet;
      if (!finding.quoted_code) {
        return finding.snippet?.unavailable_reason
          ? { lines: [], unavailableReason: finding.snippet.unavailable_reason }
          : null;
      }
      const sourceLines = String(finding.quoted_code).split("\n");
      const visible = sourceLines.slice(0, 7).map((text) => ({
        kind: text.startsWith("+") ? "added" : text.startsWith("-") ? "removed" : "context",
        text
      }));
      if (sourceLines.length > visible.length) visible.push({ kind: "ellipsis", text: "" });
      return { lines: visible };
    }

    buildReviewFindingModelV2(finding, { expanded = false, openInFiles = false } = {}) {
      const detailParts = [
        finding.details?.why,
        finding.details?.suggested_fix || finding.details?.suggestion,
        finding.details?.background
      ].filter(Boolean);
      const confidenceRaw = Number(finding.confidence);
      const model = {
        id: finding.id,
        title: finding.title || finding.body || finding.category || "Review finding",
        severity: finding.severity || "info",
        confidencePercent: Number.isFinite(confidenceRaw)
          ? (confidenceRaw <= 1 ? confidenceRaw * 100 : confidenceRaw)
          : undefined,
        filePath: finding.file || finding.original_file,
        startLine: finding.start_line || finding.original_start_line || finding.line,
        endLine: finding.end_line || finding.original_end_line || finding.line,
        summary: finding.summary || finding.details?.why,
        details: detailParts.length ? detailParts.join("\n\n") : finding.details_text,
        snippet: this.buildDiffSnippetModelV2(finding),
        lifecycle: finding.lifecycle,
        reviewedShortSHA: String(finding.reviewed_head_sha || "").slice(0, 7) || undefined,
        ...this.lifecycleChipV2(finding),
        expanded,
        onToggle: openInFiles
          ? () => this.navigateToFindingV2(finding)
          : () => this.openFindingsDrawerV2([finding], `finding-${finding.id}`),
        onOpenInFiles: openInFiles ? () => this.navigateToFindingV2(finding) : undefined,
        onOpenInEditor: this.editorURLV2(finding)
          ? () => this.window.open(this.editorURLV2(finding), "_blank", "noopener")
          : undefined,
        onDismiss: this.hasScope("finding:write") ? () => {
          this.dismissFinding(finding.id).then((dismissed) => {
            if (!dismissed) return;
            this.filesFindingPanelMount?.destroy();
            this.filesFindingPanelMount = null;
            this.selectedFilesFindingID = null;
            this.render();
          });
        } : undefined,
        onRequestDismissPermission: this.hasScope("finding:write")
          ? undefined
          : () => this.requestFindingWriteV2(),
        onRawDiagnostics: () => this.openApp(),
        onShowReviewedRevision: this.reviewedRevisionFilesURLV2(finding)
          ? () => {
              this.window.location.href = this.reviewedRevisionFilesURLV2(finding);
            }
          : undefined
      };
      // The copy text is derived from the very model the surface renders, so a
      // pasted finding always matches what the reader sees.
      model.onCopyFinding = () => this.copyTextV2(
        global.GhprSurfaceRenderers?.findingCopyText(model)
      );
      return model;
    }

    // Clipboard writes go through Tampermonkey first because the async
    // Clipboard API is blocked whenever the document is not focused.
    async copyTextV2(text) {
      const value = String(text || "");
      if (!value) return false;
      try {
        if (typeof this.gm.setClipboard === "function") {
          await this.gm.setClipboard(value);
          return true;
        }
      } catch {
        // fall through to the DOM clipboard paths
      }
      try {
        const clipboard = this.window.navigator?.clipboard;
        if (clipboard && typeof clipboard.writeText === "function") {
          await clipboard.writeText(value);
          return true;
        }
      } catch {
        // fall through to the execCommand path
      }
      return this.copyTextWithSelectionV2(value);
    }

    copyTextWithSelectionV2(value) {
      const document = this.document;
      if (typeof document.execCommand !== "function") return false;
      const field = document.createElement("textarea");
      field.value = value;
      field.setAttribute("aria-hidden", "true");
      field.style.position = "fixed";
      field.style.opacity = "0";
      document.body.appendChild(field);
      try {
        field.select();
        return document.execCommand("copy") === true;
      } catch {
        return false;
      } finally {
        field.remove();
      }
    }

    async requestFindingWriteV2() {
      try {
        await this.bridge.pair(
          null,
          ["finding:write"],
          this.window.location.origin === "https://github.com" ? this.window.location.href : null
        );
        await this.refresh();
      } catch (error) {
        this.renderTransientError(error.message);
      }
    }

    openFindingsDrawerV2(findings, instanceKey = "drawer", triggerEl) {
      if (!this.drawerHost) return;
      const SR = global.GhprSurfaceRenderers;
      if (!SR) return;
      const finding = findings.length === 1 ? findings[0] : null;
      const actions = [];
      const reviewedRevisionURL = finding ? this.reviewedRevisionFilesURLV2(finding) : null;
      if (reviewedRevisionURL) {
        actions.push({
          id: "view-reviewed-revision",
          label: "View reviewed revision",
          onSelect: () => {
            this.window.location.href = reviewedRevisionURL;
          }
        });
      }
      if (finding && this.page?.type === "pull_request" && this.hasScope("skill:run")) {
        actions.push({
          id: "review-latest-revision",
          label: "Review latest revision",
          onSelect: () => this.startPRReviewV2()
        });
      }
      const content = SR.renderSurface(this.document, "detail_drawer", {
        title: finding
          ? (finding.title || finding.body || finding.category || "Finding")
          : "ghpr findings",
        subtitle: finding
          ? [
              finding.file || finding.original_file,
              finding.lifecycle,
              finding.reviewed_head_sha ? `reviewed ${finding.reviewed_head_sha.slice(0, 7)}` : null
            ].filter(Boolean).join(" · ")
          : `${findings.length} findings`,
        sections: findings.map((item) => ({
          heading: item.file || item.original_file || "Finding",
          body: SR.renderReviewFinding(this.document, this.buildReviewFindingModelV2(item, { expanded: true }))
        })),
        actions
      });
      content.dataset.ghprInstance = instanceKey;
      this.drawerHost.open(content, { triggerEl });
    }

    reviewRunsForSummaryV2() {
      return [...(this.snapshot?.runs || [])]
        .filter((run) => run.skill_id === "pr.review")
        .sort((left, right) => {
          const leftTime = String(left.completed_at || left.started_at || left.created_at || "");
          const rightTime = String(right.completed_at || right.started_at || right.created_at || "");
          return rightTime.localeCompare(leftTime) || String(right.id).localeCompare(String(left.id));
        });
    }

    renderFilesTreeBadgesV2() {
      const selector = "[data-ghpr-file-tree-badge]";
      if (!isFilesChangedSurface(this.window.location)) {
        for (const badge of this.document.querySelectorAll(selector)) badge.remove();
        return;
      }
      const findingsByFile = new Map();
      for (const finding of this.anchoredFindingsForSurfaceV2()) {
        const path = this.normalizeDiffPathV2(finding.file || finding.original_file);
        if (!path) continue;
        const findings = findingsByFile.get(path) || [];
        findings.push(finding);
        findingsByFile.set(path, findings);
      }
      for (const item of semanticTargets(this.document, "files.tree.file")) {
        const fileLink = item.querySelector("a[href^='#diff-']");
        const content = fileLink?.parentElement?.parentElement;
        const path = this.normalizeDiffPathV2(item.id);
        const findings = findingsByFile.get(path) || [];
        let badge = item.querySelector(selector);
        if (!fileLink || !content || !findings.length) {
          badge?.remove();
          continue;
        }
        if (badge?.tagName !== "BUTTON") {
          badge?.remove();
          badge = null;
        }
        if (!badge) {
          badge = createElement(this.document, "button", {
            className: "ghpr-file-tree-badge",
            attributes: {
              type: "button",
              [MANAGED_ATTRIBUTE]: "",
              "data-ghpr-file-tree-badge": ""
            }
          });
          content.append(badge);
        }
        const label = `Open first of ${findings.length} ghpr ${findings.length === 1 ? "finding" : "findings"} in ${path}`;
        badge.textContent = String(findings.length);
        badge.setAttribute("aria-label", label);
        badge.title = label;
        badge.onclick = (event) => {
          event.preventDefault();
          event.stopPropagation();
          this.selectFindingInFilesV2(global.GhprSurfaceRenderers, findings[0]);
        };
      }
    }

    normalizeDiffPathV2(value) {
      return String(value || "")
        .replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
        .trim();
    }

    diffContainerPathV2(container) {
      if (!container) return null;
      const explicit = container.getAttribute("data-tagsearch-path")
        || container.getAttribute("data-path")
        || container.querySelector("[data-path]")?.getAttribute("data-path");
      const headerPath = container.querySelector("[data-diff-header-wrapper] h3 code")?.textContent;
      return this.normalizeDiffPathV2(explicit || headerPath) || null;
    }

    diffContainersV2() {
      return [
        ...this.document.querySelectorAll(
          "[data-tagsearch-path], .file[data-path], [role='region'][id^='diff-']"
        )
      ];
    }

    diffContainerForFindingV2(finding) {
      const paths = [finding?.file, finding?.original_file]
        .map((path) => this.normalizeDiffPathV2(path))
        .filter(Boolean);
      if (!paths.length) return null;
      return this.diffContainersV2()
        .find((container) => paths.includes(this.diffContainerPathV2(container))) || null;
    }

    diffTableForFindingV2(finding) {
      return this.diffContainerForFindingV2(finding)
        ?.querySelector("table.diff-table, table[data-diff-anchor]") || null;
    }

    renderFilesFileHeadersV2(SR, mount) {
      if (!isFilesChangedSurface(this.window.location)) return;
      const fileTables = semanticTargets(this.document, "files.diff.line-decoration");
      const findings = this.anchoredFindingsForSurfaceV2();
      if (!findings.length) return;
      const byFile = new Map();
      for (const finding of findings) {
        const path = finding.file || finding.original_file;
        // File-scoped means the finding has no diff line to sit on at all. A
        // line-anchored finding whose row is not rendered yet (collapsed or
        // lazy-loaded diff) stays pending for the diff-line pass instead of
        // being relabelled as file-level.
        if (!path || finding.line) continue;
        if (!byFile.has(path)) byFile.set(path, []);
        byFile.get(path).push(finding);
      }
      for (const table of fileTables) {
        const container = table.closest(
          "[data-tagsearch-path], .file[data-path], [role='region'][id^='diff-']"
        );
        const path = this.diffContainerPathV2(container);
        const fileFindings = path ? byFile.get(path) : undefined;
        if (!fileFindings?.length) continue;
        for (const finding of fileFindings) {
          const expanded = finding.id === this.selectedFileFindingID;
          const model = expanded
            ? {
                ...this.buildReviewFindingModelV2(finding, { expanded: true }),
                fileLevel: true,
                onCollapse: () => {
                  this.selectedFileFindingID = null;
                  this.render();
                }
              }
            : {
                ...this.buildReviewFindingModelV2(finding),
                fileLevel: true,
                showSummary: true,
                snippet: null,
                onToggle: () => {
                  this.selectedFileFindingID = finding.id;
                  this.render();
                }
              };
          const content = mount(
            SR.SURFACE_IDS.filesFileHeader,
            table.parentNode,
            model,
            expanded ? "review_finding" : "review_finding_preview",
            {
              instanceKey: `${path}#${finding.id}`,
              subjectKey: finding.id,
              anchor: table,
              position: "before"
            }
          );
          if (content) content.dataset.ghprFindingScope = "file";
          if (content && this._pendingFileFindingScrollV2 === finding.id) {
            this._pendingFileFindingScrollV2 = null;
            content.scrollIntoView?.({ block: "center" });
          }
        }
      }
    }

    renderFilesDiffLineSurfacesV2(SR, mount) {
      if (!isFilesChangedSurface(this.window.location)) return;
      const allFindings = this.anchoredFindingsForSurfaceV2();
      const findings = allFindings.filter((finding) => finding.file && finding.line);
      const groups = new Map();
      for (const finding of findings) {
        const row = this.locateDiffRowV2(finding);
        if (!row) continue;
        const cell = this.locateDiffCellV2(row, finding);
        if (!cell) continue;
        const side = finding.side === "left" || finding.side === "deletion" ? "left" : "right";
        const key = `${finding.file}:${side}:${finding.line}`;
        if (!groups.has(key)) groups.set(key, { row, cell, findings: [] });
        groups.get(key).findings.push(finding);
      }
      for (const [key, group] of groups) {
        for (const finding of group.findings) {
          const ordered = [finding, ...group.findings.filter((item) => item !== finding)];
          mount(
            SR.SURFACE_IDS.filesDiffLineAfter,
            group.cell,
            {
              ...this.buildReviewFindingModelV2(finding, {
                expanded: finding.id === this.selectedFilesFindingID
              }),
              inline: true,
              showSummary: true,
              snippet: null,
              locationLabel: this.findingAnchorLabelV2(finding),
              onToggle: (_id, element) => this.openInlineFindingPanelV2(
                SR,
                group.row,
                ordered,
                element
              )
            },
            "review_finding_preview",
            { instanceKey: `${key}#${finding.id}`, subjectKey: finding.id, position: "append" }
          );
        }
      }
    }

    findingAnchorLabelV2(finding) {
      const start = Number(finding.start_line || finding.original_start_line || finding.line);
      const end = Number(finding.end_line || finding.original_end_line || finding.line);
      const parts = [];
      if (Number.isFinite(start) && start > 0) {
        parts.push(Number.isFinite(end) && end > start ? `L${start}-L${end}` : `L${start}`);
      }
      const reviewed = String(finding.reviewed_head_sha || "").slice(0, 7);
      if (reviewed) parts.push(reviewed);
      return parts.join(" · ");
    }

    openInlineFindingPanelV2(SR, row, findings, triggerEl) {
      this.drawerHost?.close();
      if (!row?.parentNode || !findings.length) return;
      this.filesFindingPanelMount?.destroy();
      const selected = findings[0];
      this.selectedFilesFindingID = selected.id;
      const allFindings = this.anchoredFindingsForSurfaceV2();
      const selectedIndex = allFindings.findIndex((finding) => finding.id === selected.id);
      const panel = this.document.createElement("div");
      panel.className = "ghpr-inline-finding-card";
      panel.dataset.testid = "ghpr-inline-finding-panel";
      if (selectedIndex >= 0) {
        panel.append(SR.renderItemNavigator(this.document, {
          position: selectedIndex + 1,
          total: allFindings.length,
          noun: allFindings.length === 1 ? "finding" : "findings",
          ariaLabel: "Review findings navigation",
          previousID: "previous-finding",
          nextID: "next-finding",
          onPrevious: selectedIndex > 0
            ? () => this.selectFindingInFilesV2(SR, allFindings[selectedIndex - 1])
            : undefined,
          onNext: selectedIndex + 1 < allFindings.length
            ? () => this.selectFindingInFilesV2(SR, allFindings[selectedIndex + 1])
            : undefined
        }));
      }
      for (const finding of findings) {
        panel.append(SR.renderReviewFinding(
          this.document,
          this.buildReviewFindingModelV2(finding, { expanded: true })
        ));
      }
      const cell = this.document.createElement("td");
      cell.colSpan = Math.max(row.children.length, 1);
      cell.append(panel);
      const panelRow = this.document.createElement("tr");
      panelRow.className = "ghpr-inline-finding-row";
      panelRow.append(cell);
      this.filesFindingPanelMount = new SR.SurfaceMount({
        document: this.document,
        surfaceId: SR.SURFACE_IDS.filesDiffLineAfter,
        host: row.parentNode,
        anchor: row,
        position: "after",
        instanceKey: `panel-${selected.id}`,
        subjectKey: selected.id
      });
      this.filesFindingPanelMount.mount(panelRow);
      for (const preview of this.document.querySelectorAll(
        ".ghpr-review-finding-preview[data-inline='true']"
      )) {
        const isSelected = preview.getAttribute("data-ghpr-subject-key") === selected.id;
        preview.setAttribute("data-expanded", isSelected ? "true" : "false");
        preview.setAttribute("aria-expanded", isSelected ? "true" : "false");
      }
      if (triggerEl) {
        triggerEl.setAttribute("aria-expanded", "true");
        if (triggerEl.hasAttribute?.("data-expanded")) {
          triggerEl.setAttribute("data-expanded", "true");
        }
      }
    }

    selectFindingInFilesV2(SR, finding) {
      if (!finding) return;
      const url = new URL(this.window.location.href);
      url.searchParams.set("ghpr_finding", finding.id);
      this.window.history.replaceState({}, "", url);
      this._navigatedFindingIDV2 = null;
      this.handleFindingNavigationV2(SR, this.anchoredFindingsForSurfaceV2());
    }

    locateDiffRowV2(finding) {
      const table = this.diffTableForFindingV2(finding);
      if (!table) return null;
      const line = String(finding.line);
      const isLeft = finding.side === "left" || finding.side === "deletion";
      const modernSide = isLeft ? "left" : "right";
      const modernCell = table.querySelector(
        `td[data-line-anchor][data-diff-side="${modernSide}"][data-line-number="${line}"]`
      );
      if (modernCell) return modernCell.closest("tr");
      const legacySide = isLeft ? "deletion" : "addition";
      const numberCell = table.querySelector(
        `td.blob-num-${legacySide}[data-line-number="${line}"]`
      );
      return numberCell?.closest("tr") || null;
    }

    locateDiffCellV2(row, finding) {
      const isLeft = finding.side === "left" || finding.side === "deletion";
      const modernSide = isLeft ? "left" : "right";
      return row.querySelector(`td[data-line-anchor][data-diff-side="${modernSide}"]`)
        || row.querySelector(`.blob-code-${isLeft ? "deletion" : "addition"}`);
    }

    collapsedDiffDisclosureV2(fileContainer) {
      const header = fileContainer?.querySelector(
        "[data-testid='file-header'], .file-header, [data-diff-header-wrapper]"
      );
      if (!header) return null;
      for (const button of header.querySelectorAll("button")) {
        const labelledBy = button.getAttribute("aria-labelledby");
        const labelledText = labelledBy
          ? labelledBy.split(/\s+/)
              .map((id) => this.document.getElementById(id)?.textContent || "")
              .join(" ")
          : "";
        const label = [
          button.getAttribute("aria-label"),
          button.getAttribute("title"),
          labelledText
        ].filter(Boolean).join(" ");
        if (/\b(?:expand|show)\b.*\b(?:file|diff)\b/i.test(label)) return button;
      }
      return header.querySelector("details:not([open]) > summary");
    }

    handleFindingNavigationV2(SR, findings) {
      const params = new URLSearchParams(this.window.location.search);
      const findingID = params.get("ghpr_finding");
      if (!findingID) {
        this._navigatedFindingIDV2 = null;
        for (const timer of this._findingNavigationTimersV2.values()) {
          this.window.clearTimeout(timer);
        }
        this._findingNavigationTimersV2.clear();
        return;
      }
      if (this._navigatedFindingIDV2 === findingID) return;
      const finding = findings.find((item) => item.id === findingID);
      if (!finding) {
        this._navigatedFindingIDV2 = findingID;
        this.openFindingsDrawerV2([], "finding-missing");
        return;
      }
      // No diff line at all: the finding belongs to the file-level band when its
      // file is on this page, and to the drawer when the file is not.
      if (!finding.line || !(finding.file || finding.original_file)) {
        this._navigatedFindingIDV2 = findingID;
        if (this.diffTableForFindingV2(finding)) {
          this.selectedFileFindingID = finding.id;
          this._pendingFileFindingScrollV2 = finding.id;
          return;
        }
        this.openFindingsDrawerV2([finding], `finding-${finding.id}`);
        return;
      }
      const fileContainer = this.diffContainerForFindingV2(finding);
      let row = this.locateDiffRowV2(finding);
      if (!row) {
        this.collapsedDiffDisclosureV2(fileContainer)?.click();
        row = this.locateDiffRowV2(finding);
      }
      if (!row) {
        if (!this._findingNavigationTimersV2.has(findingID)) {
          const timer = this.window.setTimeout(() => {
            this._findingNavigationTimersV2.delete(findingID);
            if (this._navigatedFindingIDV2 === findingID) return;
            this._navigatedFindingIDV2 = findingID;
            this.openFindingsDrawerV2([finding], `finding-${finding.id}`);
          }, 10_000);
          this._findingNavigationTimersV2.set(findingID, timer);
        }
        return;
      }
      const navigationTimer = this._findingNavigationTimersV2.get(findingID);
      if (navigationTimer) this.window.clearTimeout(navigationTimer);
      this._findingNavigationTimersV2.delete(findingID);
      this._navigatedFindingIDV2 = findingID;
      this.openInlineFindingPanelV2(SR, row, [finding]);
      row.scrollIntoView?.({ block: "center" });
      const highlightedRows = [];
      const startLine = Number(finding.start_line || finding.line);
      const endLine = Number(finding.end_line || finding.line);
      for (let line = startLine; line <= endLine; line += 1) {
        const target = this.locateDiffRowV2({ ...finding, line });
        if (target && !highlightedRows.includes(target)) highlightedRows.push(target);
      }
      for (const target of highlightedRows) target.classList.add("ghpr-v2-highlight");
      [...this.document.querySelectorAll("[data-finding-id]")]
        .find((element) => element.getAttribute("data-finding-id") === finding.id)
        ?.querySelector(".ghpr-review-finding-title")
        ?.focus();
      if (this._highlightTimer) this.window.clearTimeout(this._highlightTimer);
      this._highlightTimer = this.window.setTimeout(() => {
        for (const target of highlightedRows) target.classList.remove("ghpr-v2-highlight");
        this._highlightTimer = null;
      }, 2000);
    }

    navigateToFindingV2(finding) {
      if (!finding) return;
      const repo = this.snapshot?.page?.repository || this.page?.repository;
      const number = this.snapshot?.page?.pr_number || this.page?.pr_number;
      try {
        this.window.sessionStorage?.setItem(`ghpr.finding.${repo}#${number}`, finding.id);
      } catch (_) {
        // Session storage may be unavailable; the query param still carries the finding ID.
      }
      const href = this.findingURL(finding);
      if (href) this.window.location.href = href;
    }

    runtimeOptionsV2(skill) {
      const allowed = new Set(skill?.agents || ["omp", "claude_code", "codex"]);
      const preferences = new Map(
        (this.snapshot?.agent_runtime || []).map((setting) => [setting.agent, setting.preference || {}])
      );
      const catalogs = new Map(
        (this.snapshot?.agent_catalogs || []).map((catalog) => [catalog.agent, catalog])
      );
      return ["omp", "claude_code", "codex"]
        .filter((agent) => allowed.has(agent))
        .map((agent) => {
          const preference = preferences.get(agent) || {};
          const catalog = catalogs.get(agent) || {};
          return {
            id: agent,
            label: labelForSkillAgent(agent),
            selectedModel: preference.model || "",
            selectedReasoningEffort: preference.reasoning_effort || "",
            models: (catalog.models || []).map((model) => ({
              slug: model.slug,
              displayName: model.display_name || model.slug,
              defaultEffort: model.default_effort || "",
              reasoningEfforts: model.reasoning_efforts || []
            })),
            reasoningEfforts: catalog.reasoning_efforts || []
          };
        });
    }

    reviewImportPromptV2(subject) {
      return [
        `Review ${subject.repository}#${subject.pr_number} at the exact revision below:`,
        `base_sha: ${subject.base_sha}`,
        `head_sha: ${subject.head_sha}`,
        "",
        "When the review is complete, call the configured ghpr MCP tool `import_review` with:",
        "- repository and PR number",
        "- the exact base_sha and head_sha above",
        "- your review engine name and overview_markdown",
        "- every actionable line finding with file, start_line, end_line, side, title, summary, severity, confidence, and category",
        "",
        "Do not submit a GitHub review or comment. Save the result only through ghpr.import_review."
      ].join("\n");
    }

    startPRReviewV2(agentID = null) {
      const SR = global.GhprSurfaceRenderers;
      const subject = this.snapshot?.current_revision_subject;
      if (!SR || !this.modalHost || subject?.type !== "pull_request_revision") {
        this.renderTransientError("The latest pull request revision is not available yet.");
        return;
      }
      const reviewSkill = (this.snapshot?.skills || []).find((skill) => skill.id === "pr.review");
      const runtimes = reviewSkill?.is_runnable === false ? [] : this.runtimeOptionsV2(reviewSkill);
      if (agentID && !runtimes.some((runtime) => runtime.id === agentID)) {
        this.renderTransientError("The selected review agent is no longer available.");
        return;
      }
      const latestReviewRun = this.reviewRunsForSummaryV2().find((run) => run.agent);
      const selectedRuntime = agentID || (runtimes.some((runtime) => runtime.id === latestReviewRun?.agent)
        ? latestReviewRun.agent : reviewSkill?.default_agent || runtimes[0]?.id);
      if (!selectedRuntime || !runtimes.length) {
        this.renderTransientError("No review agents are available.");
        return;
      }
      const content = SR.renderSurface(this.document, "review_launch_dialog", {
        repository: subject.repository, number: subject.pr_number, baseSHA: subject.base_sha, headSHA: subject.head_sha,
        runtimes, selectedRuntime,
        onStart: async (selection) => {
          const started = await this.runPRReviewV2(selection);
          if (started) this.modalHost?.close();
          return started;
        },
        onCopyImportPrompt: () => this.copyTextV2(this.reviewImportPromptV2(subject))
      });
      this.modalHost.open(content, { triggerEl: this.document.activeElement, ariaLabel: "Review pull request" });
    }

    async runPRReviewV2(runtimeSelection) {
      return this.startPullRequestSkillV2("pr.review", runtimeSelection);
    }

    async startPullRequestSkillV2(skillID, runtimeSelection = null) {
      if (!this.page?.repository || !this.page?.pr_number) return false;
      const pendingKey = `${skillID}::${this.page.key}`;
      if (this.pendingSubjectRuns.has(pendingKey)) return false;
      this.pendingSubjectRuns.add(pendingKey);
      try {
        const revision = await this.bridge.request(
          "POST",
          "/api/v1/subjects/resolve",
          {
            type: "pull_request_revision",
            repository: this.page.repository,
            pr_number: this.page.pr_number
          }
        );
        const subject = {
          type: "pull_request_revision",
          repository: revision.repository,
          pr_number: revision.pr_number,
          base_sha: revision.base_sha,
          head_sha: revision.head_sha
        };
        const alreadyReviewed = skillID === "pr.review" &&
          (this.snapshot?.runs || []).some((run) => {
            const codeReview = run.result?.code_review;
            if (!codeReview) return false;
            const reviewedHeadSHA = codeReview.head_sha || run.subject?.head_sha;
            return reviewedHeadSHA &&
              reviewedHeadSHA.toLowerCase() === revision.head_sha.toLowerCase();
          });
        if (
          alreadyReviewed &&
          !this.window.confirm(
            `Revision ${revision.head_sha.slice(0, 7)} has already been reviewed. Review it again?`
          )
        ) {
          this.pendingSubjectRuns.delete(pendingKey);
          return false;
        }
        const subjectKey = [
          "github:pull-request-revision:",
          revision.repository.toLowerCase(),
          "#",
          revision.pr_number,
          "@",
          revision.base_sha,
          "..",
          revision.head_sha
        ].join("");
        this.pendingSubjectRuns.delete(pendingKey);
        this.runSkillForSubjectV2(skillID, subject, subjectKey, runtimeSelection);
        return true;
      } catch (error) {
        this.renderTransientError(error.message);
        this.pendingSubjectRuns.delete(pendingKey);
        return false;
      }
    }

    menuSection(label) {
      const section = createElement(this.document, "div", { className: "ghpr-section" });
      if (label) {
        section.append(createElement(this.document, "div", {
          className: "ghpr-section-label",
          text: label
        }));
      }
      return section;
    }
    renderRunnableSkills() {
      const runnableSkills = this.snapshot?.skills?.filter((skill) => skill.is_runnable) || [];
      if (!runnableSkills.length) return null;
      const skills = createElement(this.document, "details", { className: "ghpr-section" });
      skills.append(createElement(this.document, "summary", { text: "Run Skill" }));
      for (const skill of runnableSkills) {
        skills.append(this.runAction(skill.display_name, {
          kind: "run_skill",
          skill_id: skill.id
        }));
      }
      return skills;
    }


    hasScope(scope) {
      return Boolean(this.bridge.client?.scopes?.includes(scope));
    }

    actionScope(action) {
      // rerun_failed_jobs acts on GitHub's own check result and is gated by an
      // explicit confirmation instead of the Skill-running scope.
      if (action.kind === "run_skill" || action.kind === "retry_run") {
        return "skill:run";
      }
      if (action.kind === "cancel_run") return "skill:cancel";
      if (action.kind === "set_tag" || action.kind === "remove_tag") return "tag:write";
      if (action.kind === "open_detail") return "detail:open";
      if (action.kind === "open_app" || action.kind === "show_pr") return "app:open";
      return null;
    }

    permissionPrompt(label, scope, detail) {
      const grant = button(this.document, `Grant ${label}`, async () => {
        grant.disabled = true;
        try {
          grant.textContent = "Requesting approval";
          const currentURL = this.window.location.origin === "https://github.com" && this.page
            ? this.window.location.href
            : null;
          await this.bridge.pair((message) => {
            grant.textContent = message;
          }, [scope], currentURL);
          if (!this.hasScope(scope)) {
            throw new Error(`The approval did not grant ${scope}.`);
          }
          await this.refresh();
          this.renderTransientError(`${PERMISSION_LABELS[scope] || scope} enabled. Choose the action again.`);
        } catch (error) {
          grant.disabled = false;
          grant.textContent = `Grant ${label}`;
          this.renderTransientError(error.message);
        }
      }, "ghpr-button ghpr-button-primary");
      return createElement(this.document, "aside", {
        className: "ghpr-update-notice ghpr-permission-notice",
        attributes: { role: "status" }
      }, [
        createElement(this.document, "div", { className: "ghpr-update-copy" }, [
          createElement(this.document, "strong", { text: `${scope} required` }),
          createElement(this.document, "span", { text: detail })
        ]),
        grant
      ]);
    }

    updateAvailable() {
      return isVersionNewer(
        this.bridge.discovery?.official_userscript_version,
        CLIENT.version
      );
    }

    renderUpdateNotice() {
      const latest = this.bridge.discovery?.official_userscript_version;
      if (!this.updateAvailable() || !this.bridge.baseURL) return null;
      const update = button(this.document, "Update", () => {
        this.gm.openInTab(`${this.bridge.baseURL}/install/ghpr.user.js`);
      }, "ghpr-button ghpr-button-primary");
      update.setAttribute("aria-label", `Update ghpr for GitHub to ${latest}`);
      return createElement(this.document, "aside", {
        className: "ghpr-update-notice",
        attributes: { role: "status" }
      }, [
        createElement(this.document, "div", { className: "ghpr-update-copy" }, [
          createElement(this.document, "strong", { text: "Userscript update available" }),
          createElement(this.document, "span", {
            text: `${CLIENT.version} → ${latest}`
          })
        ]),
        update
      ]);
    }

    panelAction(label, callback) {
      return button(this.document, label, callback, "ghpr-panel-action");
    }

    menuAction(label, callback) {
      const control = button(this.document, label, callback, "ghpr-panel-action");
      control.setAttribute("role", "menuitem");
      return control;
    }

    panelSection(label) {
      return this.menuSection(label);
    }

    activeRunForSkill(skillID) {
      if (!skillID) return null;
      return this.snapshot?.runs?.find((run) =>
        run.skill_id === skillID &&
        (run.status === "queued" || run.status === "running")
      ) || null;
    }

    actionSkillID(action) {
      if (!action) return null;
      if (action.kind === "run_skill") return action.skill_id || null;
      if (action.kind === "retry_run") {
        return this.snapshot?.runs?.find((run) => run.id === action.run_id)?.skill_id || null;
      }
      return null;
    }

    runActionBusy(action) {
      const skillID = this.actionSkillID(action);
      if (!skillID) return false;
      return this.pendingSkillRuns.has(skillID) ||
        Boolean(this.activeRunForSkill(skillID));
    }

    markRunActionBusy(control, label) {
      if ("disabled" in control) control.disabled = true;
      control.setAttribute("aria-disabled", "true");
      control.classList.add("ghpr-busy");
      control.title = "This Skill is already running. Wait for it to finish or cancel it.";
      if (label !== null) control.textContent = `${label} · Running`;
    }

    runAction(label, action, className = "ghpr-panel-action") {
      const control = button(this.document, label, () => {
        if (control.disabled) return;
        this.markRunActionBusy(control, label);
        this.invokeAction(action);
      }, className);
      if (this.runActionBusy(action)) this.markRunActionBusy(control, label);
      return control;
    }

    async withRunGuard(action, operation) {
      const skillID = this.actionSkillID(action);
      if (skillID) {
        if (this.pendingSkillRuns.has(skillID)) return;
        if (this.activeRunForSkill(skillID)) {
          this.renderTransientError(`${skillID} is already running.`);
          return;
        }
        this.pendingSkillRuns.add(skillID);
      }
      try {
        await operation();
      } finally {
        if (skillID) this.pendingSkillRuns.delete(skillID);
      }
    }

    renderRunningCard(run) {
      const host = semanticTargets(this.document, "pr.mergebox.after")[0];
      if (!host) return;
      const progress = run.progress_total
        ? `${run.progress_current || 0} / ${run.progress_total}`
        : "In progress";
      const actions = [];
      if (this.hasScope("detail:open")) {
        actions.push(button(this.document, "View live log", () =>
          this.invokeAction({ kind: "open_detail", run_id: run.id })
        ));
      }
      if (this.hasScope("skill:cancel")) {
        actions.push(button(this.document, "Cancel", () =>
          this.invokeAction({ kind: "cancel_run", run_id: run.id })
        ));
      }
      const card = createElement(this.document, "section", {
        className: "ghpr-card ghpr-run-card",
        attributes: { [MANAGED_ATTRIBUTE]: "", "aria-label": "ghpr Skill Running" }
      }, [
        createElement(this.document, "div", { className: "ghpr-card-head" }, [
          createElement(this.document, "span", {
            className: "ghpr-card-title",
            text: run.skill_id
          }),
          createElement(this.document, "span", {
            className: "ghpr-badge ghpr-tone-analysis",
            text: "Running"
          })
        ]),
        createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: run.progress_message || "Waiting for Skill output…"
        }),
        createElement(this.document, "div", { className: "ghpr-metrics" }, [
          this.metric(progress, "Progress"),
          this.metric(run.status, "Status")
        ])
      ]);
      if (actions.length) {
        card.append(createElement(this.document, "div", {
          className: "ghpr-action-row"
        }, actions));
      }
      host.insertAdjacentElement("afterend", card);
    }


    latestCodeReview() {
      return [...(this.snapshot?.runs || [])]
        .sort((left, right) =>
          String(right.completed_at || "").localeCompare(String(left.completed_at || ""))
        )
        .map((run) => run.result?.code_review)
        .find(Boolean) || null;
    }

    jobNameForRow(row) {
      const explicit = row.dataset.jobName ||
        row.querySelector("[data-check-name], [data-job-name]")?.textContent;
      if (explicit?.trim()) return explicit.trim();
      const statusPattern = /\b(failed|failure|success|passed|skipped|cancelled|queued|running)\b/i;
      const candidates = [...row.querySelectorAll("a, [title], span, strong, p")];
      return candidates
        .map((candidate) => candidate.textContent?.trim())
        .find((text) => text && !statusPattern.test(text) && text.length <= 160) || null;
    }

    analysisForCheck(row) {
      const text = (this.jobNameForRow(row) || row.textContent || "").trim().toLocaleLowerCase();
      const analyses = this.snapshot?.analyses || [];
      return analyses.find((analysis) => {
        const name = String(analysis.job_name || "").trim().toLocaleLowerCase();
        return name && (name === text || text.includes(name));
      }) || null;
    }

    findingURL(finding) {
      const page = this.snapshot?.page;
      const number = page?.pr_number;
      if (!page || !number || !finding) return null;
      // A finding whose anchor no longer resolves on the latest revision is
      // only viewable on the diff of the commit it was reviewed against.
      if (!finding.file) return this.reviewedRevisionFilesURLV2(finding);
      const url = new URL(
        `https://github.com/${page.repository}/pull/${number}/changes`
      );
      url.searchParams.set("ghpr_finding", finding.id);
      url.searchParams.set("path", finding.file);
      if (finding.line) {
        url.searchParams.set("line", String(finding.line));
        url.hash = `L${finding.line}`;
      }
      return url.href;
    }

    navigateToFinding(finding) {
      const href = this.findingURL(finding);
      if (href) this.window.location.href = href;
    }

    editorURLV2(finding) {
      const page = this.snapshot?.page;
      const revision = this.snapshot?.current_revision_subject;
      const file = finding?.file;
      const line = finding?.end_line || finding?.line;
      if (!page?.repository || !revision?.head_sha || !file || !line) return null;
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(page.repository)) return null;
      if (!/^[0-9a-f]{40}$/i.test(revision.head_sha)) return null;
      if (file.startsWith("/") || file.split("/").includes("..")) return null;
      return `https://github.dev/${page.repository}/blob/${revision.head_sha}/${file}#L${line}`;
    }

    async dismissFinding(findingID) {
      if (!this.hasScope("finding:write")) {
        this.renderTransientError("finding:write permission is required to dismiss this finding.");
        return false;
      }
      try {
        await this.bridge.request(
          "POST",
          `/api/v1/findings/${encodeURIComponent(findingID)}/dismiss`
        );
        if (this.snapshot?.findings) {
          this.snapshot.findings = this.snapshot.findings.filter((finding) => finding.id !== findingID);
        }
        return true;
      } catch (error) {
        this.renderTransientError(error.message);
        return false;
      }
    }

    renderFinding(finding, { inline = false } = {}) {
      const confidence = confidencePercent(finding.confidence);
      const location = finding.line ? `${finding.file}:${finding.line}` : finding.file;
      const element = createElement(this.document, inline ? "div" : "article", {
        className: inline ? "ghpr-inline-panel" : "ghpr-finding",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "data-testid": "ghpr-review-finding",
          "data-finding-id": finding.id
        }
      });
      const head = createElement(this.document, "div", {
        className: "ghpr-finding-head"
      }, [
        createElement(this.document, "span", {
          className: "ghpr-finding-title",
          text: finding.body || finding.category || "Review finding"
        }),
        createElement(this.document, "span", {
          className: `ghpr-badge ghpr-tone-${findingSeverityTone(finding.severity)}`,
          text: `${finding.severity || "info"}${confidence ? ` · ${confidence}` : ""}`
        })
      ]);
      element.append(
        head,
        createElement(this.document, "div", {
          className: "ghpr-finding-meta",
          text: location
        })
      );
      if (finding.quoted_code) {
        element.append(createElement(this.document, "pre", {
          className: "ghpr-mini-diff",
          text: finding.quoted_code
        }));
      }
      if (finding.details?.why) {
        element.append(createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: finding.details.why
        }));
      }
      const tools = createElement(this.document, "div", {
        className: "ghpr-finding-tools"
      });
      if (!inline && this.findingURL(finding)) {
        tools.append(button(this.document, "View in Files changed", () =>
          this.navigateToFinding(finding)
        ));
      }
      if (inline) {
        const raw = createElement(this.document, "pre", {
          className: "ghpr-mini-diff ghpr-raw-diagnostics",
          text: JSON.stringify(finding, null, 2)
        });
        raw.hidden = true;
        tools.append(
          button(this.document, "Dismiss", async () => {
            await this.dismissFinding(finding.id);
            element.remove();
          }),
          createElement(this.document, "button", {
            className: "ghpr-button",
            text: "Open in editor",
            type: "button",
            title: "Local editor integration is not configured.",
            disabled: true
          }),
          button(this.document, "Raw diagnostics", () => {
            raw.hidden = !raw.hidden;
          })
        );
        element.append(raw);
      }
      if (tools.children.length) element.append(tools);
      return element;
    }

    renderReviewSummaryCard(review) {
      const host = semanticTargets(this.document, "pr.mergebox.after")[0];
      if (!host) return;
      const findings = review.findings || [];
      const card = createElement(this.document, "section", {
        className: "ghpr-card ghpr-review-summary",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "aria-label": "ghpr Review Summary"
        }
      }, [
        createElement(this.document, "div", { className: "ghpr-card-head" }, [
          createElement(this.document, "span", {
            className: "ghpr-card-title",
            text: "ghpr Review Summary"
          }),
          createElement(this.document, "span", {
            className: "ghpr-badge ghpr-tone-analysis",
            text: "Beta"
          })
        ]),
        createElement(this.document, "div", {
          className: "ghpr-review-meta",
          text: `Reviewed revision: ${review.head_sha || "current"} · ${findings.length} findings · ${new Set(findings.map((finding) => finding.file)).size} files`
        }),
        createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: review.overview_markdown || "Review findings from ghpr."
        })
      ]);
      for (const finding of findings) card.append(this.renderFinding(finding));
      host.insertAdjacentElement("afterend", card);
    }

    renderAnalysisCard() {
      const currentRun = this.snapshot.runs.find((run) =>
        run.status === "queued" || run.status === "running"
      );
      if (currentRun) {
        this.renderRunningCard(currentRun);
        return;
      }
      const review = this.latestCodeReview();
      if (review) {
        this.renderReviewSummaryCard(review);
        return;
      }
      const analysis = this.snapshot.analyses[0];
      if (!analysis) return;
      const host = semanticTargets(this.document, "pr.mergebox.after")[0];
      if (!host) return;
      const card = createElement(this.document, "section", {
        className: "ghpr-card",
        attributes: { [MANAGED_ATTRIBUTE]: "", "aria-label": "ghpr CI Analysis" }
      });
      const badge = createElement(this.document, "span", {
        className: `ghpr-badge ghpr-tone-${toneForVerdict(analysis.verdict)}`,
        text: `${labelForVerdict(analysis.verdict)} · ${analysis.confidence}`
      });
      const cardActions = [];
      cardActions.push(button(this.document, "Rerun", () =>
        this.rerunFailedChecksV2(global.GhprSurfaceRenderers)
      ));
      if (this.hasScope("tag:write")) {
        cardActions.push(button(this.document, "Mark locally as flaky", () =>
          this.invokeAction({ kind: "set_tag", tag: "flaky" })
        ));
      }
      if (this.hasScope("detail:open")) {
        cardActions.push(button(this.document, "Full Analysis", () =>
          this.invokeAction({ kind: "open_detail", analysis_id: analysis.id })
        ));
      }
      card.append(
        createElement(this.document, "div", { className: "ghpr-card-head" }, [
          createElement(this.document, "span", { className: "ghpr-card-title", text: "ghpr CI Analysis" }),
          badge
        ]),
        createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: analysis.summary
        }),
        createElement(this.document, "div", { className: "ghpr-metrics" }, [
          this.metric(`${analysis.history_matches.length} / ${analysis.history_checked}`, "History"),
          this.metric(
            analysis.relatedness_score == null
              ? "—"
              : `${Math.round(analysis.relatedness_score * 100)}%`,
            "Relatedness"
          ),
          this.metric(analysis.reproduction, "Reproduction")
        ])
      );
      if (cardActions.length) {
        card.append(createElement(this.document, "div", {
          className: "ghpr-action-row"
        }, cardActions));
      }
      host.insertAdjacentElement("afterend", card);
    }

    metric(value, label) {
      return createElement(this.document, "div", { className: "ghpr-metric" }, [
        createElement(this.document, "strong", { text: String(value) }),
        createElement(this.document, "span", { text: label })
      ]);
    }

    renderInsight(analysis) {
      const insight = createElement(this.document, "div", {
        className: "ghpr-insight",
        attributes: { [MANAGED_ATTRIBUTE]: "" }
      });
      insight.append(
        createElement(this.document, "h4", { text: "Why it failed" }),
        createElement(this.document, "p", { text: analysis.summary || "No failure summary yet." }),
        createElement(this.document, "h4", { text: "Flaky evidence" }),
        createElement(this.document, "p", {
          text: analysis.relatedness_summary || analysis.suggested_action || "No additional evidence."
        }),
        createElement(this.document, "h4", { text: "History" }),
        createElement(this.document, "p", {
          text: `${analysis.history_matches?.length || 0} / ${analysis.history_checked || 0} matching runs`
        }),
        createElement(this.document, "h4", { text: "Suggested action" }),
        createElement(this.document, "p", { text: analysis.suggested_action || "Inspect the full result." })
      );
      return insight;
    }

    renderCheckActions(jobName) {
      const actions = createElement(this.document, "details", {
        className: "ghpr-check-actions",
        attributes: { [MANAGED_ATTRIBUTE]: "" }
      });
      actions.append(createElement(this.document, "summary", { text: "Analyze ▾" }));
      for (const [label, skillID] of [
        ["Explain CI Failure", "ci.failure.explain"],
        ["Classify Flaky", "ci.failure.classify_flaky"]
      ]) {
        actions.append(this.runAction(label, {
          kind: "run_skill",
          skill_id: skillID,
          job_name: jobName
        }, "ghpr-button"));
      }
      return actions;
    }
    renderCheckRows() {
      if (this.page?.type !== "pull_request") return;
      const candidates = semanticTargets(this.document, "checks.run.trailing");
      for (const row of candidates) {
        if (!/\b(failed|failure)\b/i.test(row.textContent || "")) continue;
        if (row.querySelector(":scope > .ghpr-check-tools")) continue;
        const analysis = this.analysisForCheck(row);
        const jobName = analysis?.job_name || this.jobNameForRow(row);
        if (!jobName) continue;
        const activeRuns = (this.snapshot.runs || []).filter((run) =>
          ["queued", "running"].includes(run.status)
        );
        const activeRun = activeRuns.find((run) => {
          const runJob = run.preferred_job_name || run.result?.analysis?.job_name;
          return runJob && runJob.toLocaleLowerCase() === jobName.toLocaleLowerCase();
        }) || (activeRuns.length === 1 ? activeRuns[0] : null);
        const tools = createElement(this.document, "span", {
          className: "ghpr-check-tools",
          attributes: { [MANAGED_ATTRIBUTE]: "" }
        });
        if (activeRun) {
          tools.append(createElement(this.document, "span", {
            className: "ghpr-badge ghpr-tone-analysis",
            text: "Running"
          }));
          if (this.hasScope("detail:open")) {
            tools.append(button(this.document, "View log", () =>
              this.invokeAction({ kind: "open_detail", run_id: activeRun.id })
            ));
          }
          if (this.hasScope("skill:cancel")) {
            tools.append(button(this.document, "Cancel", () =>
              this.invokeAction({ kind: "cancel_run", run_id: activeRun.id })
            ));
          }
        } else {
          if (analysis) {
            tools.append(createElement(this.document, "span", {
              className: `ghpr-badge ghpr-tone-${toneForVerdict(analysis.verdict)}`,
              text: `${labelForVerdict(analysis.verdict)}${confidencePercent(analysis.confidence_score) ? ` · ${confidencePercent(analysis.confidence_score)}` : ""}`
            }));
          }
          if (this.hasScope("skill:run")) {
            tools.append(this.renderCheckActions(jobName));
          }
        }
        if (analysis) {
          const insight = createElement(this.document, "details", {
            className: "ghpr-check-insight",
            attributes: { [MANAGED_ATTRIBUTE]: "" }
          });
          insight.open = true;
          insight.append(
            createElement(this.document, "summary", { text: "ghpr CI Insight" }),
            this.renderInsight(analysis)
          );
          row.append(insight);
        }
        if (tools.children.length) row.append(tools);
      }
    }

    findingsForSnapshot(allowLegacyFallback = true) {
      const review = this.latestCodeReview();
      const reviewFindings = review?.findings || [];
      const persisted = (this.snapshot.findings || []).map((finding) => {
        const original = finding.subject || {};
        const resolved = ["exact", "remapped"].includes(finding.lifecycle)
          ? (finding.resolved_subject || original)
          : {};
        const payload = reviewFindings.find((candidate) => candidate.id === finding.id) || {};
        return {
          id: finding.id,
          title: finding.title,
          body: finding.summary,
          summary: finding.summary,
          details_text: finding.details,
          details: payload.details,
          severity: finding.severity,
          confidence: finding.confidence,
          category: finding.kind,
          fingerprint: finding.fingerprint,
          lifecycle: finding.lifecycle,
          file: resolved.file_path,
          side: resolved.side,
          start_line: resolved.start_line,
          end_line: resolved.end_line,
          line: resolved.end_line,
          original_file: original.file_path,
          original_start_line: original.start_line,
          original_end_line: original.end_line,
          original_side: original.side,
          reviewed_head_sha: original.head_sha,
          reviewed_base_sha: original.base_sha,
          quoted_code: original.quoted_code,
          snippet: payload.snippet,
          subject_key: finding.subject_key
        };
      });
      if (persisted.length) return persisted;
      if (!allowLegacyFallback) return [];
      if (reviewFindings.length) return reviewFindings;
      return (this.snapshot.analyses || []).flatMap((analysis) => analysis.findings || []);
    }

    renderWorkflowRunInsight() {
      const host = semanticTargets(this.document, "checks.job.trailing")[0];
      if (!host || host.querySelector(":scope > .ghpr-workflow-insight")) return;
      const analysis = this.snapshot.analyses?.[0] ||
        this.snapshot.runs?.find((run) => run.result?.analysis)?.result?.analysis;
      if (!analysis) return;
      const card = createElement(this.document, "section", {
        className: "ghpr-card ghpr-workflow-insight",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "aria-label": "ghpr CI Insight"
        }
      }, [
        createElement(this.document, "div", {
          className: "ghpr-card-title",
          text: "ghpr CI Insight"
        }),
        this.renderInsight(analysis)
      ]);
      host.append(card);
    }

    renderFilesFindings() {
      const hosts = semanticTargets(this.document, "files.diff.line-decoration");
      if (!hosts.length) return;
      const findings = this.findingsForSnapshot();
      if (!findings.length) return;
      const host = hosts[0];
      if (host.querySelector(":scope > .ghpr-files-findings")) return;
      const section = createElement(this.document, "section", {
        className: "ghpr-card ghpr-files-findings",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "aria-label": "ghpr Findings in Files changed"
        }
      }, [
        createElement(this.document, "div", {
          className: "ghpr-card-title",
          text: "ghpr Findings"
        })
      ]);
      for (const finding of findings) {
        section.append(this.renderFinding(finding, { inline: true }));
      }
      host.insertAdjacentElement("beforebegin", section);
    }

    async renderContributions(fallbackHost) {
      const fallback = this.panelSection("Extensions");
      fallback.classList.add("ghpr-fallback");
      let fallbackCount = 0;
      const health = [];
      for (const contribution of this.snapshot.contributions) {
        const hosts = semanticTargets(this.document, contribution.slot);
        const healthy = hosts.length > 0;
        health.push({
          page_key: this.page.key,
          slot: contribution.slot,
          healthy,
          detail: healthy ? "Mounted by ghpr for GitHub." : "Semantic anchor was not found."
        });
        if (healthy) {
          for (const host of hosts) {
            host.append(this.renderContribution(contribution));
          }
        } else {
          fallback.append(this.renderContribution(contribution, true));
          const headerFallback = this.headerMenu?.querySelector("[data-ghpr-header-fallback]");
          if (headerFallback) {
            headerFallback.hidden = false;
            headerFallback.append(this.renderContribution(contribution, true));
          }
          fallbackCount += 1;
        }
      }
      if (fallbackCount) fallbackHost.append(fallback);
      for (const report of health) {
        this.bridge.request("POST", "/api/v1/slot-health", report).catch(() => {});
      }
    }

    renderContribution(contribution, fallbackStyle = false) {
      const component = contribution.component;
      const label = component.label || component.text || contribution.id;
      const requiredScope = contribution.action
        ? this.actionScope(contribution.action)
        : null;
      if (requiredScope && !this.hasScope(requiredScope)) {
        const repair = this.permissionPrompt(
          this.contributionActionLabel(contribution.action),
          requiredScope,
          `${requiredScope} is required for this contribution.`
        );
        repair.dataset.ghprContribution = `${contribution.client_id}:${contribution.id}`;
        return repair;
      }
      const canInvoke = Boolean(contribution.action) &&
        (!requiredScope || this.hasScope(requiredScope));
      const runBusy = this.runActionBusy(contribution.action);
      let element;
      let actionControl = null;
      if (component.type === "result_card" && !fallbackStyle) {
        const children = [
          createElement(this.document, "div", { className: "ghpr-card-head" }, [
            createElement(this.document, "span", { className: "ghpr-card-title", text: label }),
            createElement(this.document, "span", {
              className: `ghpr-badge ghpr-tone-${component.tone || "neutral"}`,
              text: "Skill result"
            })
          ])
        ];
        if (component.text) {
          children.push(createElement(this.document, "p", {
            className: "ghpr-card-summary",
            text: component.text
          }));
        }
        if (contribution.action) {
          const actionLabel = this.contributionActionLabel(contribution.action);
          actionControl = button(
            this.document,
            actionLabel,
            () => canInvoke && !actionControl.disabled && this.invokeContribution(contribution),
            "ghpr-button ghpr-button-primary"
          );
          if (runBusy) this.markRunActionBusy(actionControl, actionLabel);
          children.push(createElement(this.document, "div", {
            className: "ghpr-action-row"
          }, [actionControl]));
        }
        element = createElement(this.document, "section", {
          className: "ghpr-card",
          attributes: {
            [MANAGED_ATTRIBUTE]: "",
            "aria-label": label
          }
        }, children);
      } else if (component.type === "badge") {
        element = createElement(this.document, "span", {
          className: `ghpr-badge ghpr-tone-${component.tone || "neutral"}`,
          text: label,
          attributes: { [MANAGED_ATTRIBUTE]: "" }
        });
        if (contribution.action) {
          actionControl = element;
          if (runBusy) {
            this.markRunActionBusy(element, null);
          } else if (canInvoke) {
            element.setAttribute("role", "button");
            element.tabIndex = 0;
            element.addEventListener("click", () => this.invokeContribution(contribution));
          }
        }
      } else {
        element = button(
          this.document,
          label,
          () => canInvoke && !element.disabled && this.invokeContribution(contribution),
          fallbackStyle ? "ghpr-panel-action" : "ghpr-button"
        );
        actionControl = element;
        element.disabled = !canInvoke;
        element.setAttribute(MANAGED_ATTRIBUTE, "");
        if (runBusy) this.markRunActionBusy(element, label);
      }
      if (actionControl && requiredScope && !this.hasScope(requiredScope)) {
        if ("disabled" in actionControl) actionControl.disabled = true;
        actionControl.setAttribute("aria-disabled", "true");
        actionControl.title = `${requiredScope} required`;
      }
      element.dataset.ghprContribution = `${contribution.client_id}:${contribution.id}`;
      return element;
    }

    contributionActionLabel(action) {
      if (action.kind === "open_detail") return "Open Full Analysis";
      if (action.kind === "run_skill") return "Run Skill";
      if (action.kind === "retry_run") return "Retry";
      if (action.kind === "cancel_run") return "Cancel";
      return "Open";
    }

    async invokeContribution(contribution) {
      await this.withRunGuard(
        contribution.action,
        () => this.sendContribution(contribution)
      );
    }

    async sendContribution(contribution) {
      const requiredScope = contribution.action
        ? this.actionScope(contribution.action)
        : null;
      if (requiredScope && !this.hasScope(requiredScope)) {
        this.renderTransientError(
          `${requiredScope} is not granted. Use the permission action in the ghpr card.`
        );
        return;
      }
      try {
        const response = await this.bridge.request(
          "POST",
          `/api/v1/contributions/${encodeURIComponent(contribution.client_id)}/${encodeURIComponent(contribution.id)}/invoke?page_key=${encodeURIComponent(contribution.page_key)}`
        );
        this.openResponseURL(response);
        await this.refresh();
      } catch (error) {
        this.renderTransientError(error.message);
      }
    }

    async invokeAction(action) {
      await this.withRunGuard(
        action,
        () => this.sendAction(action)
      );
    }
    async invokeConfirmedAction(action) {
      await this.withRunGuard(
        action,
        () => this.sendAction(action, true)
      );
    }


    async sendAction(action, confirmed = false) {
      if (!this.page || !this.bridge.client) return;
      const requiredScope = this.actionScope(action);
      if (requiredScope && !this.hasScope(requiredScope)) {
        this.renderTransientError(
          `${requiredScope} is not granted. Use the permission action in the ghpr card.`
        );
        return;
      }
      try {
        const response = await this.bridge.request("POST", "/api/v1/actions", {
          action,
          page: this.page,
          confirmed
        });
        this.openResponseURL(response);
        await this.refresh();
      } catch (error) {
        this.renderTransientError(error.message);
      }
    }

    openResponseURL(response) {
      if (!response?.url) return;
      if (/^https?:\/\//.test(response.url)) {
        this.gm.openInTab(response.url);
      } else {
        this.window.location.href = response.url;
      }
    }

    async openApp() {
      if (!this.page) this.page = parseGitHubPage(this.window.location);
      if (!this.page) return;
      if (!this.bridge.baseURL) await this.bridge.discover();
      if (!this.bridge.token) await this.bridge.authenticate();
      await this.invokeAction({ kind: "open_app" });
    }

    renderTransientError(message) {
      if (!message) return;
      this.actionError = String(message);
      this.menuOpen = true;
      const menu = this.headerMenu
        || this.document.getElementById(HEADER_ENTRY_ID)?.querySelector(".ghpr-header-menu");
      if (menu) {
        this.syncHeaderMenu(menu, { rebuild: true });
        return;
      }
      if (this.drawerHost && global.GhprSurfaceRenderers) {
        const content = global.GhprSurfaceRenderers.renderSurface(
          this.document,
          "detail_drawer",
          { title: "ghpr unavailable", raw: String(message) }
        );
        this.drawerHost.open(content);
      }
    }
  }

  function createGhprApp(options = {}) {
    const window = options.window || global.window || global;
    const document = options.document || window.document;
    const gm = options.gm || createGMAdapter(options.gmSource);
    return new GhprGitHubApp({ window, document, gm });
  }

  const exported = {
    BridgeClient,
    BridgeError,
    CLIENT,
    GhprGitHubApp,
    createElement,
    createGMAdapter,
    isVersionNewer,
    isConversationSurface,
    isFilesChangedSurface,
    filesChangedRevisionRef,
    createGhprApp,
    parseGitHubPage,
    semanticTargets
  };
  global.GhprUserscript = exported;
  if (typeof module !== "undefined" && module.exports) module.exports = exported;

  if (!global.__GHPR_TEST__ && global.document) {
    createGhprApp().start().catch((error) => {
      // A missing local app resolves silently inside refresh(); reaching this
      // handler means the userscript itself failed, so it must say so instead
      // of leaving the page untouched with no explanation.
      global.console?.error?.("[ghpr] userscript failed to start:", error);
    });
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
