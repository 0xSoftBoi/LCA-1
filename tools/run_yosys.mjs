// SPDX-License-Identifier: Apache-2.0
import fs from "node:fs";
import path from "node:path";
import { Exit, runYosys } from "@yowasp/yosys";

const ignored = new Set([
  ".git",
  ".venv",
  "__pycache__",
  "build",
  "dist",
  "node_modules",
  "simv",
]);

function loadTree(directory) {
  const tree = {};
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (ignored.has(entry.name) || entry.name.endsWith(".pyc")) continue;
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) tree[entry.name] = loadTree(absolute);
    else if (entry.isFile()) {
      tree[entry.name] = new Uint8Array(fs.readFileSync(absolute));
    }
  }
  return tree;
}

function materialize(tree, directory) {
  fs.mkdirSync(directory, { recursive: true });
  for (const [name, value] of Object.entries(tree ?? {})) {
    const absolute = path.join(directory, name);
    if (typeof value === "object" && !(value instanceof Uint8Array)) {
      materialize(value, absolute);
    } else {
      fs.writeFileSync(absolute, value);
    }
  }
}

function stream(target) {
  return (bytes) => {
    if (bytes !== null) target.write(Buffer.from(bytes));
  };
}

const files = loadTree(process.cwd());
files.reports ??= {};

try {
  const result = await runYosys(process.argv.slice(2), files, {
    stdout: stream(process.stdout),
    stderr: stream(process.stderr),
  });
  if (result?.reports) {
    materialize(result.reports, path.join(process.cwd(), "reports"));
  }
} catch (error) {
  if (error instanceof Exit) {
    if (error.files?.reports) {
      materialize(error.files.reports, path.join(process.cwd(), "reports"));
    }
    process.exit(error.code);
  }
  throw error;
}
