// compose-at.mjs <toolkit-dir> <generatedAt> <compose option>...: run the
// `deploy-kit compose` an installed toolkit ships, with its clock stopped at
// the moment a recorded composition ran.
//
// `deploy-kit compose` reads the clock once, as the lock's
// `metadata.generatedAt`, and a participant's age is measured against it
// (deploy-kit spec/v1/40-composition.md#participants): the same fragment
// composed later can be stale where it was not. The command takes no option
// for its clock, so this calls the command's own entry point, `main`, which
// takes the clock and the toolkit's release as its arguments, exactly as the
// installed `deploy-kit` binary does, with the clock given here instead.
//
// <toolkit-dir> is where `npm install --prefix` put the toolkit, and
// <generatedAt> is the recorded lock's `metadata.generatedAt`. It writes,
// prints and exits as `deploy-kit compose` does.
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [toolkit, at, ...options] = process.argv.slice(2);
if (toolkit === undefined || at === undefined || Number.isNaN(Date.parse(at))) {
  process.stderr.write(
    "usage: compose-at.mjs <toolkit-dir> <generatedAt> <compose option>...\n",
  );
  process.exit(2);
}

const root = resolve(toolkit, "node_modules", "@jorisjonkers-dev", "deploy-kit");
const { version } = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const load = (path) => import(pathToFileURL(join(root, "dist", "cli", path)).href);
const { main } = await load("main.js");
const { perform } = await load("boundary.js");
if (typeof main !== "function" || typeof perform !== "function") {
  process.stderr.write(
    `deploy-kit ${version} exports no main(argv, world) to compose with a recorded clock\n`,
  );
  process.exit(2);
}

perform(main(["compose", ...options], { now: () => at, toolkitVersion: version }));
