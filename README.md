# PR Dashboard

A lightweight macOS menu bar app for tracking your GitHub pull requests and review requests.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)

![Screenshot](assets/screenshot.png)

## Installation

### Homebrew (Recommended)

```bash
brew install xiaocang/tap/prdashboard
```

### Manual Download

1. Download the latest release from [Releases](https://github.com/xiaocang/ghpr-view/releases)
2. Extract the ZIP file
3. Move `PRDashboard.app` to your Applications folder
4. Open the app (you may need to right-click → Open the first time)


## Features

- **Menu Bar App** - Lives in your menu bar, no dock icon clutter
- **PR Overview** - View authored PRs, review requests, mentioned PRs, and direct mentions in one place
- **Merged Today** - Dedicated section showing PRs merged in the last 24 hours
- **Search & Summary** - Filter with free text or `jira:`, `ci:`, `pr:conflict`, and `approval:` queries
- **PR Actions** - Pin PRs, manage comment read state, rerun failed CI, and update out-of-date branches
- **CI Status** - See CI check status (success/failure/pending) for each PR
- **CI Workflow Grouping** - CI checks grouped by workflow with running status indicators
- **Rerun Failed CI** - Rerun failed CI checks directly from the dashboard
- **Unresolved Comments** - Badge shows unresolved comment count for your authored PRs
- **Approval Count** - Badge shows approval count on PR rows
- **Review Status** - Shows your review status (approved, changes requested, etc.) on review-requested PRs
- **Jira Integration** - Enrich detected Jira tickets with titles, statuses, and labels
- **Activity Monitoring** - Background monitoring of PRs you author, review or comment on: reviews, review comments, thread state, review requests, and CI, with per-PR "why this concerns me" reasons and a native **Activity** window
- **Digest Notifications** - At most one digest every 30 minutes, delivered to macOS notifications, a Slack direct message, or both, and only when something actually needs you
- **Comment Shortcuts** - Your own comment templates with `{{repository}}`, `{{pr_number}}`, `{{head_sha}}` and related variables, prepared against canonical PR context
- **Rate Limit Display** - Shows GitHub API rate limit in footer
- **Local Integrations** - Query the running app over a local Unix socket with `ghpr` (read-only) or the bundled MCP server (read-only tools plus `import_review` to persist an externally produced code review)
- **GitHub Browser Integration** - Official `ghpr for GitHub` userscript adds CI analysis, Skill actions, tags, and local detail views to GitHub PR and Actions pages
- **Extension Platform** - Versioned Skill, presentation, and browser-contribution contracts with scoped third-party userscript capabilities
- **Skill Workbench** - Create, migrate, validate, fixture-test, preview, package, and install ghpr Skills

## Usage

### Option 1: GitHub Device Flow (Recommended)

1. Click the menu bar icon to open the dashboard
2. Click "Sign in with GitHub"
3. Enter the displayed code at github.com/login/device
4. Once authorized, your PRs will load automatically

### Option 2: Personal Access Token (PAT)

1. Create a [Personal Access Token](https://github.com/settings/tokens) with `repo`, `read:user`, `workflow`, and `read:org` scopes
2. Click the menu bar icon to open the dashboard
3. Click "Sign in with GitHub", then "Use Personal Access Token"
4. Paste your token and click "Sign In"

### Controls

- **Left-click** menu bar icon - Open PR dashboard
- **Right-click** menu bar icon - Show context menu (version info, quit)
- **Cmd+R** - Refresh PR list
- **Settings** (gear icon) - Configure the account, refresh behavior, filters, integrations, notifications, and updates

### Activity Monitoring and Digests

PR Dashboard remembers which PRs you author, are asked to review, have reviewed, or have commented on, and keeps observing them locally while the app is running. Observation starts with the app, not with the popover, and runs no more often than every five minutes (or your Refresh Interval when that is longer).

- The **Activity** button in the dashboard header (tray icon) opens the activity window. It groups what needs your attention per PR, shows why each item concerns you, links to the evidence, and offers **Handled**, **Snooze**, **Mute notifications**, and **Track**/**Stop tracking**. Muting or snoozing affects delivery only: collection and the existing unread counts are unchanged.
- The first complete observation of each PR is recorded silently as a baseline, so an existing backlog is never replayed as new notifications. After that, each real change (new review, review comment, thread reply, resolved or reopened thread, review request, new revision, new failing check on the current revision) becomes an event with a stable identity; re-reading an unchanged PR creates nothing.
- A digest is built at most once every 30 minutes, only when at least one item is newly actionable and not muted or filtered out, and at most five PRs are listed per digest (the remainder stay in the Activity window). Delivery goes to the targets you chose in Settings; nothing is sent while there is nothing new.
- Delivery receipts are kept per target: a delivered channel is marked delivered, a failure stays retryable from the Activity window, and a request whose outcome is unknown (timeout or a crash while sending) is marked unknown and is never retried automatically, because Slack offers no verified cross-crash idempotency.
- Monitoring is local: it only runs while this Mac, its network, and PR Dashboard are available. Activity that appears and disappears while the app is offline cannot be reconstructed. The app never writes to GitHub on your behalf — reviewing, commenting, re-requesting review and rerunning CI stay manual actions.
- Monitored history lives in `~/Library/Application Support/ghpr/activity/v1/<account>.json`, one file per GitHub account (endpoint plus viewer node ID). Signing out or switching accounts never deletes another account's history. If a history file is damaged it is kept untouched and the error is shown in the Activity window instead of silently restarting.

### Slack Direct Message

Digests can be delivered to your own Slack DM through a Slack app you create and install in your workspace:

1. Create a Slack app in your workspace and add the `chat:write`, `im:write` and `users:read` scopes. No event subscriptions, no bot channels, no hosted OAuth are needed.
2. Install the app to the workspace and copy its bot token (`xoxb-…`).
3. In **Settings → Slack Direct Message**, paste the token and your own Slack user ID (for example `U0123ABCDEF`), then click **Verify and Connect**. ghpr checks the token and workspace with `auth.test`, confirms your user with `users.info`, and opens the DM with `conversations.open`.
4. Use **Send test DM** for a manual connection test; it is clearly labelled and is not a PR digest.

The token is stored in the macOS credential store (Keychain in Release builds), never in configuration, saved history, logs, browser snapshots or exports. Digests only contain short summaries and links: never full diffs, whole reviews, logs or secrets, and GitHub text is escaped so mentions and links cannot ping or unfurl.

### Comment Shortcuts

Comment shortcuts are your own templates, empty by default. Add them in **Settings → Comment Shortcuts**, for example `Please add a test for {{pr_path}}` style text using the supported variables `{{repository}}`, `{{pr_number}}`, `{{pr_url}}`, `{{head_sha}}`, `{{diff_url}}`, and — only when you are replying to a comment — `{{comment_url}}` and `{{comment_body}}`. Each shortcut can be limited to a context (PR comment, conversation reply, review comment reply), to specific repositories, and can be enabled or disabled.

When the userscript is installed, the compact ghpr menu lists the shortcuts that apply to the current PR and comment. Selecting one asks the app to prepare a draft from **canonical** PR data fetched with your own account (the page's repository, comment body and revision are treated as hints only): a revision change, a comment that belongs to another PR, a missing context or a missing permission aborts the preparation with an error instead of inserting something wrong. The draft is plain text that you review and submit yourself.

### Local CLI

Build the command-line tool:

```bash
make build-cli
```

`make build-cli` prints the built `ghpr` path. Add it to your `PATH` or run that binary directly. Run PRDashboard, then query its current in-memory snapshot:

```bash
ghpr status
ghpr ping
ghpr prs --section authored
ghpr prs --section direct-mentions
ghpr pr --repo owner/repo --number 123
ghpr prs --json
ghpr snapshot --json
```

The CLI connects to a local Unix socket at `/tmp/com.xiaocang.PRDashboard.<uid>.sock` and only ever sends read commands (`status`, `ping`, `prs`, `pr`, `snapshot`). Use `GHPR_SOCKET_PATH` or `--socket PATH` to override the path.

Available `prs` sections are `authored`, `review`, `mentioned`, `direct-mentions`, `merged`, and `all`. For MCP integration, run `make install-mcp` and see [`mcp-ghpr/README.md`](mcp-ghpr/README.md).

### GitHub Browser Integration

1. Open **Settings → Browser Integration** and confirm that the loopback Browser Bridge is running.
2. Click **Install Userscript** and install `ghpr for GitHub` in Tampermonkey.
3. Open a GitHub PR or an Actions job and click the compact `ghpr` entry. Nothing is mounted before that click: the menu shows connection state (Connect/Update/Retry), **Open in ghpr**, the manual actions available on that page, comment shortcuts, and **Review results**, which stays collapsed until you expand it. GitHub's own reviewer, check and comment UI is never replaced.
4. If the userscript is not paired, choose **Connect ghpr** from the Tampermonkey userscript menu, then review the requested scopes in the native ghpr window. Read-only scopes are selected by default; running Skills, cancelling runs, dismissing findings, writing local ghpr tags, and reading artifacts require explicit approval. Local ghpr tags are stored only by ghpr and never change GitHub labels.

Review results only render when expanded, keep their expanded state while you stay on the same PR, and reset when you move to another PR. Inside the expanded panel, findings keep exact-revision matching, show staleness and dismissal, and `ghpr_finding` links scroll and highlight the target line; code annotations appear only when you ask for them. Polling and MCP imports never expand the menu or the results, never start AI work, and never overwrite text you are typing. Connect and Retry recovery controls remain available when the local app is disconnected or unavailable.

For cmux's built-in browser, run the installer from this checkout instead of using Tampermonkey:

```bash
./install-userscript.sh
# Optionally reload one existing browser surface after installation:
./install-userscript.sh --surface surface:12
```

Requires a running cmux app with userscript RPC support, plus `cmux`, `node`, and `jq` on `PATH`.
The script rebuilds `browser/ghpr.user.js` and installs it with the stable ID `ghpr-for-github`, replacing any previous installation under that ID.
Without `--surface`, open pages are left untouched; reload or navigate a GitHub tab to activate the update.

The bridge listens only on `127.0.0.1` within discovery ports `48120...48129`. Browser clients use individual revocable bearer capabilities—never cookies—and cannot obtain the GitHub token, local workspace paths, agent credentials, raw repository access, or shell execution. Third-party userscripts register declarative UI contributions through the bridge; the official userscript remains the only GitHub-page UI host.

Bridge discovery reports the version of the official userscript currently served by the app. When that version is newer than the installed script, the compact ghpr menu offers **Update ghpr userscript**, which opens the local Tampermonkey install route.

Installed Skill packages can use the strict Browser Contract v2 allowlist to bind structured results to GitHub pages; arbitrary selectors, scripts, HTML, iframes, and external URLs are rejected. Active runs show on the exact subject surface. Raw run logs and artifacts open in the local diagnostics UI and remain capability-scoped; raw Agent output and credentials are never exposed.

Use **Open Browser Test Page** to verify bridge isolation and contract support. **Open Skill Workbench** provides Create, Migrate, and Enhance flows with fixture and permission gates. The equivalent contract-driven CLI workflow is:

```bash
ghpr contract capabilities --json
ghpr contract export --version latest --json
ghpr contract examples

ghpr skill scaffold --id team.ci.policy-check --name "Team CI Policy Check"
ghpr skill validate ./team.ci.policy-check
ghpr skill test ./team.ci.policy-check
ghpr skill preview ./team.ci.policy-check
ghpr skill pack ./team.ci.policy-check
ghpr skill install ./team.ci.policy-check
```

The app's Coding Agent Integration installs both the bundled `ghpr-skill-builder` and a standalone review-import MCP for Claude Code, Codex, and OMP. The MCP executable is copied from the app bundle into stable user Application Support storage before each agent configuration is updated. The builder reads the contracts exported by the installed `ghpr` binary instead of carrying a stale copy. Workbench Enhance automatically discovers Skills in those three user scopes and adds presentation and GitHub surfaces to an app-managed copy; the source `SKILL.md` and pass-through result semantics remain unchanged.

Runnable managed Skills execute through a restricted Claude Code, Codex, or OMP CLI invocation in a private temporary run directory. `execution.isolation: strict` describes the ghpr invocation contract, not an OS sandbox: ghpr disables Agent-exposed tools, shell actions, repository checkout, and task-directed network tools; passes the package instructions, result schema, and sanitized snapshot; and builds the child environment from an explicit model-provider allowlist so ambient application and repository credential variables are not inherited. The trusted host CLI still retains its normal `HOME`, configuration/plugins, provider credentials, and provider network transport. Codex starts after its working directory is switched to the private run root (`-C`) inside a read-only sandbox. ghpr validates final structured output against the package schema before persisting it.

While an Agent CLI is running, ghpr persists a fixed, sanitized lifecycle log. Browser and native clients can observe the transition from runtime launch to Agent execution, first output, result validation, and completion without receiving raw Agent output or credentials.

Debug and UITesting builds keep GitHub, Jira, and proxy credentials in an obfuscated local file instead of invoking macOS Keychain. This storage is convenience-only and is never compiled into Release builds; Release continues to use Keychain.

The model and reasoning effort for each coding agent are selectable. Claude Code and Codex lists are read from the agents themselves — `claude --help` for Claude Code model aliases and effort levels, `codex debug models` for the Codex model catalog and its per-model reasoning levels. Both lists are fetched on first use, cached with the app state, and refreshable from Settings. OMP takes a free-form model name because it resolves fuzzy names such as `opus` or `openai/gpt-5.2` itself. When nothing is selected, each agent keeps its own default.

A GitHub PR page never submits the same Skill twice: while a run for that Skill is queued or running, its run control is greyed out, and a repeated click cannot start a second run. The local run page groups the lifecycle log into GitHub Actions-style steps, and every step expands to its detailed events.


### Settings

Settings are split into five tabs. Save and Done write every tab, not only the one on screen.

- **General** — account, launch at login, open PRs in cmux first, refresh interval, refresh on open, pause in Low Power Mode, pause on cellular/hotspot, updates
- **Pull Requests** — repository filter, draft PRs, review-status badges, minimum approvals for ready to merge, CI status exclude filter
- **Alerts** — notification master switch, background activity monitoring, digest targets, event categories, Slack direct message. Activity uses the Pull Requests repository filter; an optional repository list here narrows delivery further. Explicitly tracked PRs stay included.
- **Integrations** — Jira, browser integration, coding agent integration, comment shortcuts
- **Advanced** — replay onboarding, clear caches, GraphQL endpoint override, HTTP proxy


## Requirements

- macOS 13.0 or later
- GitHub account

## Building from Source

```bash
git clone https://github.com/xiaocang/ghpr-view.git
cd ghpr-view
./run.sh
make build-cli
make install-mcp  # optional; requires Node.js and npm
```

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.
