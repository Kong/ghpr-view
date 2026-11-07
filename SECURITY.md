# Security

## Reporting

Report a vulnerability privately through [GitHub security advisories](https://github.com/Kong/ghpr-view/security/advisories/new). Do not file a public issue for a credential leak, a local-socket bug, or a browser-bridge bug.

## What this app stores

PR Dashboard keeps credentials on this Mac. There is no PR Dashboard account.

Release builds store them in the macOS Keychain under the service `com.xiaocang.PRDashboard`:

- GitHub auth state, from device flow or a personal access token
- an optional Jira Cloud API token
- an optional Slack bot token
- an optional HTTP proxy credential

Debug builds may also write those values to `~/Library/Application Support/ghpr/debug-credentials.json`.

## Network and local interfaces

The app calls GitHub, and, only when you configure them, Jira Cloud and Slack. It does not review, comment, or merge on its own. Those GitHub actions happen when you use a control in the app.

While it is running it listens on:

- `127.0.0.1` ports 48120–48129 for the browser bridge. A userscript gets a capability token only after the app approves the pairing.
- a Unix socket at `~/Library/Application Support/ghpr/cli.sock`, mode `0600`. The server accepts only a peer with the same uid. `import_review` writes a local review record and does not submit a GitHub review.

`GHPR_SOCKET_PATH` selects the socket a client connects to. The server listens on the default path.

## Updates

Update checks read public GitHub releases for `xiaocang/ghpr-view`. The downloaded zip is checked for bundle identifier `com.xiaocang.PRDashboard` before it is installed.
