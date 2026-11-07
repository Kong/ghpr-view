#!/usr/bin/env node
// Builds the repo-root NOTICE from license files of packages embedded in
// mcp-ghpr-bundle/index.mjs. --check exits non-zero when NOTICE would change.

import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "../..");
const bundlePath = join(repoRoot, "mcp-ghpr-bundle/index.mjs");
const modulesRoot = join(here, "../node_modules");
const noticePath = join(repoRoot, "NOTICE");
const licenseNames = ["LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "COPYING"];

const bundle = readFileSync(bundlePath, "utf8");
const packageNames = new Set();
for (const match of bundle.matchAll(/node_modules\/(@[^/\s]+\/[^/\s]+|[^/\s]+)\//g)) {
  packageNames.add(match[1]);
}

function licenseText(packageDir) {
  for (const name of licenseNames) {
    const path = join(packageDir, name);
    if (existsSync(path) && statSync(path).isFile()) {
      return readFileSync(path, "utf8").trim();
    }
  }
  return null;
}

function licenseId(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object" && typeof value.type === "string") return value.type;
  return "UNKNOWN";
}

const sections = [];
const missing = [];
for (const name of [...packageNames].sort()) {
  const packageDir = join(modulesRoot, name);
  const manifestPath = join(packageDir, "package.json");
  if (!existsSync(manifestPath)) {
    missing.push(`${name} (package.json missing)`);
    continue;
  }
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const text = licenseText(packageDir);
  if (!text) missing.push(`${name} (license file missing)`);
  sections.push(
    [
      `## ${name} ${manifest.version}`,
      "",
      `License: ${licenseId(manifest.license)}`,
      "",
      text ?? "(no license file in the installed package)",
      "",
    ].join("\n"),
  );
}

if (packageNames.size === 0) {
  console.error("generate-notice: no bundled packages found in mcp-ghpr-bundle/index.mjs");
  process.exit(1);
}
if (missing.length > 0) {
  console.error(`generate-notice: missing license files:\n${missing.join("\n")}`);
  process.exit(1);
}

const notice = [
  "PR Dashboard",
  "Copyright 2026 xiaocang",
  "Copyright 2026 Kong",
  "",
  "Licensed under the Apache License, Version 2.0. See LICENSE.",
  "Both names are the copyright lines in that file. This notice does not add another ownership claim.",
  "",
  "The release zip is produced by .github/workflows/swift.yml and is not stored in git.",
  "That workflow copies LICENSE and this file into PRDashboard.app before signing the app and zipping it.",
  "",
  "The following notices cover packages embedded in mcp-ghpr-bundle/index.mjs.",
  "",
  ...sections,
].join("\n");

const check = process.argv.includes("--check");
if (check) {
  const current = existsSync(noticePath) ? readFileSync(noticePath, "utf8") : "";
  if (current !== notice) {
    console.error("NOTICE is out of date. Run: node mcp-ghpr/scripts/generate-notice.mjs");
    process.exit(1);
  }
  console.log(`NOTICE matches ${packageNames.size} bundled packages.`);
} else {
  writeFileSync(noticePath, notice);
  console.log(`Wrote NOTICE for ${packageNames.size} bundled packages.`);
}
