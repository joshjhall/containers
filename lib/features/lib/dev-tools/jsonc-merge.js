#!/usr/bin/env node
'use strict';
//
// jsonc-merge — merge a JSON fragment (stdin) into a JSONC target file while
// preserving the target's comments and formatting.
//
// Why this exists: Zed's first-startup scripts (40-zed-lsp-config,
// 41-zed-agent-config) both bootstrap ~/.config/zed/settings.json, which Zed
// lets users author as JSONC (// comments). `jq` cannot parse comments, so the
// merge chain previously forced strict, comment-free JSON and lost the inline
// docs. This helper uses jsonc-parser (the Zed/VS Code ecosystem's parser) to
// edit surgically — only the merged keys change; every surrounding comment is
// kept byte-for-byte.
//
// Behavior:
//   - Fragment (valid strict JSON) is read from stdin; target path is argv[2].
//   - The merge is ADDITIVE and IDEMPOTENT: any key path already present in the
//     target is left untouched (a re-run with a different value does NOT
//     overwrite). Only missing key paths are inserted.
//   - A missing target file is treated as an empty object and written fresh.
//
// Usage:  echo '<json-fragment>' | jsonc-merge <target-file>
//
// Exit codes: 0 ok · 64 usage · 65 bad stdin JSON · 66 target not valid JSONC ·
//             69 jsonc-parser unavailable.

const fs = require('fs');
const path = require('path');

// jsonc-parser is installed alongside this helper by dev-tools.sh into a fixed
// directory (NOT the npm global prefix, which is pinned to /cache/npm-global
// and would make `-g` installs land on a droppable cache volume). Tests point
// JSONC_MERGE_LIB at a throwaway install dir.
const LIB_DIR = process.env.JSONC_MERGE_LIB || '/usr/local/lib/jsonc-merge/node_modules';

let jp;
try {
  jp = require(path.join(LIB_DIR, 'jsonc-parser'));
} catch (_e) {
  process.stderr.write('jsonc-merge: jsonc-parser not found under ' + LIB_DIR + '\n');
  process.exit(69); // EX_UNAVAILABLE
}
const { parse, parseTree, findNodeAtLocation, modify, applyEdits } = jp;

const PARSE_OPTS = { allowTrailingComma: true };
const FORMAT_OPTS = { formattingOptions: { insertSpaces: true, tabSize: 2 } };

const target = process.argv[2];
if (!target) {
  process.stderr.write('usage: jsonc-merge <target-file>  (JSON fragment on stdin)\n');
  process.exit(64); // EX_USAGE
}

let fragment;
try {
  fragment = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch (e) {
  process.stderr.write('jsonc-merge: stdin is not valid JSON: ' + e.message + '\n');
  process.exit(65); // EX_DATAERR
}

let text = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : '{}';

const parseErrors = [];
parse(text, parseErrors, PARSE_OPTS);
if (parseErrors.length) {
  process.stderr.write('jsonc-merge: ' + target + ' is not parseable as JSONC\n');
  process.exit(66); // EX_NOINPUT
}

// Flatten the fragment to leaf key-paths so we insert missing keys without
// clobbering sibling keys or comments. Empty objects/arrays are themselves
// leaves — recursing into them would yield no paths and silently drop the key
// (e.g. "env": {}, "args": []).
function isEmptyContainer(v) {
  if (Array.isArray(v)) return v.length === 0;
  return v && typeof v === 'object' && Object.keys(v).length === 0;
}

function leafPaths(obj, base) {
  let out = [];
  for (const key of Object.keys(obj)) {
    const val = obj[key];
    if (val && typeof val === 'object' && !Array.isArray(val) && !isEmptyContainer(val)) {
      out = out.concat(leafPaths(val, base.concat(key)));
    } else {
      out.push([base.concat(key), val]);
    }
  }
  return out;
}

let merged = 0;
for (const [keyPath, value] of leafPaths(fragment, [])) {
  const tree = parseTree(text, [], PARSE_OPTS);
  if (tree && findNodeAtLocation(tree, keyPath) !== undefined) {
    continue; // already present — keep the user's value
  }
  const edits = modify(text, keyPath, value, FORMAT_OPTS);
  text = applyEdits(text, edits);
  merged++;
}

fs.writeFileSync(target, text.endsWith('\n') ? text : text + '\n');
process.stderr.write('jsonc-merge: merged ' + merged + ' key path(s) into ' + target + '\n');
