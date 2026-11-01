// compose-at.mjs <toolkit-dir> <generatedAt> <compose option>...: run the
// `deploy-kit compose` an installed toolkit ships, with its clock stopped at
// the moment a recorded composition ran.
//
// `deploy-kit compose` reads the clock once, as the lock's
// `metadata.generatedAt`, and a participant's age is measured against it
// (deploy-kit spec/v1/40-composition.md#participants): the same fragment
// composed later can be stale where it was not. From deploy-kit 1.7.0 the
// command takes that reading as `--now`, so this runs the installed binary
// with it. An older toolkit has no such option, and a lock it wrote is
// replayed with that same toolkit, so for those this calls the command's own
// entry point, `main`, which takes the clock and the toolkit's release as its
// arguments, exactly as the installed binary does, with the clock given here.
// `--now` takes an instant in UTC only, so a recorded time in any other form
// takes the same path.
//
// <toolkit-dir> is where `npm install --prefix` put the toolkit, and
// <generatedAt> is the recorded lock's `metadata.generatedAt`. It writes,
// prints and exits as `deploy-kit compose` does.
import { spawnSync } from "node:child_process";
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

/** The first release whose `compose` takes the clock as `--now`. */
const NOW_SINCE = [1, 7, 0];

const atLeast = (release, since) => {
  const parts = release.split(/[.-]/).slice(0, 3).map(Number);
  for (let i = 0; i < since.length; i++) {
    if (parts[i] !== since[i]) return parts[i] > since[i];
  }
  return true;
};

if (atLeast(version, NOW_SINCE) && /Z$/.test(at)) {
  const binary = resolve(toolkit, "node_modules", ".bin", "deploy-kit");
  const run = spawnSync(binary, ["compose", "--now", at, ...options], { stdio: "inherit" });
  if (run.error) {
    process.stderr.write(`deploy-kit ${version} could not be run: ${run.error.message}\n`);
    process.exit(2);
  }
  process.exit(run.status ?? 1);
}

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
