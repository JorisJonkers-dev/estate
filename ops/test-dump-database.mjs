// The handover dump writes one database to Garage's handover-dumps bucket after
// showing the plan and getting one "y", reads the object back by size and
// checksum, and restores it into a scratch database whose row counts must match
// the counts taken in the dump's own snapshot.
// Runs the real script with `kubectl` (cluster, Garage CLI, Postgres) and `aws`
// (Garage's S3 API) faked on PATH.
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmod, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Run with `node --test ops/test-dump-database.mjs`; it needs nothing installed.
const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dump-database.sh')

const tempDir = (prefix) => mkdtemp(path.join(tmpdir(), prefix))

async function writeExecutable(file, contents) {
  await writeFile(file, contents.trimStart().replace(/\n?$/, '\n'), 'utf8')
  await chmod(file, 0o755)
}

function runProcess(command, args, { env = {}, input } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.on('error', reject)
    child.on('close', (exitCode) => resolve({ exitCode, stdout, stderr }))
    // The script may exit before reading all of stdin; that EPIPE is not a failure.
    child.stdin.on('error', (error) => { if (error.code !== 'EPIPE') reject(error) })
    child.stdin.end(input ?? '')
  })
}
const SECRET = 'garage-handover-secret'

const KUBECTL = `#!/usr/bin/env node
// Fake kubectl: the Garage CLI and Postgres, logged to $FAKE_DIR/kubectl.log.
const fs = require('fs'), path = require('path')
const dir = process.env.FAKE_DIR
const args = process.argv.slice(2).filter((a, i, all) => a !== '--context' && all[i - 1] !== '--context')
const line = args.join(' ')
fs.appendFileSync(path.join(dir, 'kubectl.log'), line + '\\n')
const flag = (name) => path.join(dir, name)
const counts = (scratch) =>
  'public.execution_entity|' + (40 + (scratch && process.env.FAKE_COUNT_MISMATCH ? 1 : 0)) + '\\npublic.workflow_entity|7\\n'
if (line.includes('/garage bucket info handover-dumps')) {
  if (!fs.existsSync(flag('bucket'))) { process.stderr.write('Error: no such bucket\\n'); process.exit(1) }
  console.log('Bucket: handover-dumps')
} else if (line.includes('/garage bucket create handover-dumps')) {
  fs.writeFileSync(flag('bucket'), '')
} else if (line.includes('/garage key info handover-dumps')) {
  if (!fs.existsSync(flag('key'))) { process.stderr.write('Error: no such key\\n'); process.exit(1) }
  console.log('Key name: handover-dumps\\nKey ID: GKhandover\\nSecret key: ${SECRET}')
} else if (line.includes('/garage key create handover-dumps')) {
  fs.writeFileSync(flag('key'), '')
} else if (line.includes('/garage bucket allow')) {
  // granted
} else if (args.includes('psql') && args.includes('ON_ERROR_STOP=1')) {
  // The snapshot session: its script arrives on stdin.
  const script = fs.readFileSync(0, 'utf8')
  fs.writeFileSync(path.join(dir, 'session.sql'), script)
  process.stdout.write('PGDMP-' + args[args.indexOf('-d') + 1])
  process.stderr.write(counts(false))
} else if (args.includes('psql')) {
  process.stdout.write(counts(args[args.indexOf('-d') + 1] !== 'n8n_db'))
} else if (line.includes('pg_restore')) {
  fs.readFileSync(0)
} else if (args.includes('createdb') || args.includes('dropdb')) {
  // nothing to do
} else {
  process.stderr.write('fake kubectl: unhandled ' + line + '\\n'); process.exit(9)
}
`

const AWS = `#!/usr/bin/env node
// Fake aws: Garage's S3 API over a directory, logged with its argv.
const fs = require('fs'), path = require('path')
const dir = process.env.FAKE_DIR
const args = process.argv.slice(2)
fs.appendFileSync(path.join(dir, 'aws.log'), args.join(' ') + '\\n')
if (process.env.AWS_SECRET_ACCESS_KEY !== '${SECRET}' || process.env.AWS_ACCESS_KEY_ID !== 'GKhandover') {
  process.stderr.write('fake aws: wrong credentials\\n'); process.exit(255)
}
const at = (bucket, key) => path.join(dir, 's3', bucket, key)
if (args.includes('cp')) {
  const i = args.indexOf('cp')
  const [src, dst] = [args[i + 1], args[i + 2]]
  const [, bucket, ...rest] = dst.replace('s3://', '/').split('/')
  const target = at(bucket, rest.join('/'))
  fs.mkdirSync(path.dirname(target), { recursive: true })
  let body = fs.readFileSync(src)
  if (process.env.FAKE_S3_TRUNCATE) body = body.subarray(0, body.length - 1)
  fs.writeFileSync(target, body)
  const meta = process.env.FAKE_S3_BAD_SHA ? 'sha256=0000' : args[args.indexOf('--metadata') + 1] || ''
  fs.writeFileSync(target + '.meta', JSON.stringify(Object.fromEntries(meta.split(',').filter(Boolean).map((kv) => kv.split('=')))))
} else if (args.includes('head-object')) {
  const target = at(args[args.indexOf('--bucket') + 1], args[args.indexOf('--key') + 1])
  if (!fs.existsSync(target)) { process.stderr.write('Not Found\\n'); process.exit(254) }
  console.log(JSON.stringify({ ContentLength: fs.statSync(target).size, Metadata: JSON.parse(fs.readFileSync(target + '.meta', 'utf8')) }))
} else { process.stderr.write('fake aws: unhandled ' + args.join(' ') + '\\n'); process.exit(9) }
`

async function run(dir, args, { input, env = {} } = {}) {
  const bin = path.join(dir, 'bin')
  await mkdir(bin, { recursive: true })
  await writeExecutable(path.join(bin, 'kubectl'), KUBECTL)
  await writeExecutable(path.join(bin, 'aws'), AWS)
  const result = await runProcess('bash', [SCRIPT, ...args], {
    input,
    env: {
      PATH: `${bin}:${process.env.PATH}`,
      FAKE_DIR: dir,
      GARAGE_ENDPOINT: 'http://garage.test',
      WORK_DIR: path.join(dir, 'work'),
      ...env,
    },
  })
  const log = async (name) => {
    try {
      return (await readFile(path.join(dir, name), 'utf8')).split('\n').filter(Boolean)
    } catch {
      return []
    }
  }
  return { ...result, kubectl: await log('kubectl.log'), aws: await log('aws.log') }
}

async function stored(dir) {
  const root = path.join(dir, 's3', 'handover-dumps')
  const out = {}
  const walk = async (d) => {
    for (const e of await readdir(d, { withFileTypes: true })) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) await walk(p)
      else if (!e.name.endsWith('.meta')) out[path.relative(root, p)] = await readFile(p)
    }
  }
  try {
    await walk(root)
  } catch {
    return {}
  }
  return out
}

// True when a dropdb of the scratch database follows the restore.
const droppedAfterRestore = (lines) => {
  const restore = lines.findLastIndex((l) => l.includes('pg_restore'))
  return restore >= 0 && lines.slice(restore + 1).some((l) => l.includes('dropdb') && !l.includes('--if-exists'))
}

test('the plan names the database and the key it is written to, and asks once', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'n\n' })
  assert.match(result.stdout, /n8n_db\s+-> s3:\/\/handover-dumps\/n8n_db\/n8n_db-\d{8}T\d{6}Z\.dump/)
  assert.equal((result.stdout.match(/\[y\/N\]/g) || []).length, 1)
})

test('without y the dump changes nothing', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'n\n' })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual(result.aws, [])
  assert.deepEqual(result.kubectl.filter((l) => /create|bucket allow|psql|createdb/.test(l)), [])
})

test('a confirmed dump is written to the handover-dumps bucket and reported with what Garage holds', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'y\n' })
  assert.equal(result.exitCode, 0, result.stdout + result.stderr)
  const objects = Object.entries(await stored(dir))
  assert.equal(objects.length, 1)
  const [[key, body]] = objects
  assert.match(key, /^n8n_db\/n8n_db-\d{8}T\d{6}Z\.dump$/)
  assert.equal(body.toString(), 'PGDMP-n8n_db')
  const sha = createHash('sha256').update(body).digest('hex')
  assert.match(result.stdout, new RegExp(`${key.replace(/[.]/g, '\\.')}\\s+${body.length}\\s+${sha}`))
})

test('the dump and the row counts it is checked against come from one snapshot', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'y\n' })
  assert.equal(result.exitCode, 0, result.stderr)
  const session = await readFile(path.join(dir, 'session.sql'), 'utf8')
  const at = (needle) => session.indexOf(needle)
  assert.ok(at('begin isolation level repeatable read') >= 0, session)
  assert.ok(at('pg_export_snapshot()') > at('begin isolation level repeatable read'), session)
  assert.ok(at('--snapshot="$SNAP"') > at('pg_export_snapshot()'), session)
  assert.ok(at('query_to_xml') > at('--snapshot="$SNAP"'), session)
  assert.ok(at('commit') > at('query_to_xml'), session)
})

test('the dump is restored into a scratch database whose row counts match, then dropped', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'y\n' })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.match(result.stdout, /row counts match \(2 tables\)/)
  assert.ok(droppedAfterRestore(result.kubectl))
})

test('a scratch restore whose row counts differ fails the run, and the scratch database is still dropped', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'y\n', env: { FAKE_COUNT_MISMATCH: '1' } })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /row counts differ/)
  assert.ok(droppedAfterRestore(result.kubectl))
})

test('a dump Garage holds at the wrong size fails the run', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'y\n', env: { FAKE_S3_TRUNCATE: '1' } })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /size/)
})

test('a dump Garage reports with a different checksum fails the run', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'y\n', env: { FAKE_S3_BAD_SHA: '1' } })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /checksum/)
})

test('the bucket and its key are created only when missing, and the key is granted on the bucket', async () => {
  const dir = await tempDir('dump-')
  const first = await run(dir, ['run', 'n8n_db'], { input: 'y\n' })
  assert.equal(first.kubectl.filter((l) => l.includes('/garage bucket create handover-dumps')).length, 1)
  assert.equal(first.kubectl.filter((l) => l.includes('/garage key create handover-dumps')).length, 1)
  assert.ok(first.kubectl.some((l) => /\/garage bucket allow --read --write handover-dumps --key handover-dumps/.test(l)))
  await writeFile(path.join(dir, 'kubectl.log'), '')
  const second = await run(dir, ['run', 'n8n_db'], { input: 'y\n' })
  assert.equal(second.kubectl.filter((l) => / create /.test(l)).length, 0)
})

test('the Garage secret never reaches a command line or the output', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db'], { input: 'y\n' })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.ok(result.aws.length > 0)
  assert.ok(result.aws.every((l) => !l.includes(SECRET)))
  assert.doesNotMatch(result.stdout + result.stderr, new RegExp(SECRET))
})

test('a database name that is not a plain identifier is refused before anything runs', async () => {
  const dir = await tempDir('dump-')
  const result = await run(dir, ['run', 'n8n_db; drop'], { input: 'y\n' })
  assert.notEqual(result.exitCode, 0)
  assert.deepEqual(result.kubectl, [])
})
