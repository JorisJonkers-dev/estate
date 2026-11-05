// The unseal script finds Vault by label rather than by name, so a rename or a
// move between namespaces does not point it at nothing, then unseals the pod it
// found with the key shares it is given, and reads the seal state back before it
// says Vault is open.
// Runs the real script with `kubectl` faked on PATH; `vault` runs inside the
// faked pod, so no local vault CLI is on PATH and the script takes its exec route.
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { chmod, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Run with `node --test ops/test-unseal-vault.mjs`; it needs nothing installed.
const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'unseal-vault.sh')

// How many shares open the fake Vault.
const THRESHOLD = 2

const KUBECTL = `#!/usr/bin/env node
// Fake kubectl: pod discovery by label, and \`vault\` inside the pod. Logged to $FAKE_DIR/kubectl.log.
const fs = require('fs'), path = require('path')
const dir = process.env.FAKE_DIR
const all = process.argv.slice(2)
const args = all.filter((a, i) => !['--context', '-n'].includes(a) && !['--context', '-n'].includes(all[i - 1]))
const line = all.filter((a, i) => a !== '--context' && all[i - 1] !== '--context').join(' ')
fs.appendFileSync(path.join(dir, 'kubectl.log'), line + '\\n')
const stateFile = path.join(dir, 'progress')
const progress = () => (fs.existsSync(stateFile) ? Number(fs.readFileSync(stateFile, 'utf8')) : 0)
if (args[0] === 'get' && args[1] === 'pods') {
  // The pods that carry the label, as "<namespace> <name>" lines.
  process.stdout.write(process.env.FAKE_PODS || '')
} else if (args[0] === 'exec') {
  const vault = args.slice(args.indexOf('--') + 2)
  if (vault[0] === 'status') {
    const sealed = progress() < ${THRESHOLD} && !process.env.FAKE_OPEN
    process.stdout.write('Key    Value\\nSealed ' + sealed + '\\n')
    process.exit(sealed ? 2 : 0)
  } else if (vault[0] === 'operator' && vault[1] === 'unseal' && vault[2] === '-reset') {
    fs.writeFileSync(stateFile, '0')
  } else if (vault[0] === 'operator' && vault[1] === 'unseal') {
    if (vault[2] !== 'good-share-1' && vault[2] !== 'good-share-2') {
      process.stderr.write('Error unsealing: message authentication failed\\n'); process.exit(2)
    }
    fs.writeFileSync(stateFile, String(progress() + 1))
  } else {
    process.stderr.write('fake vault: unhandled ' + vault.join(' ') + '\\n'); process.exit(9)
  }
} else if (args[0] === 'config') {
  // use-context and friends
} else {
  process.stderr.write('fake kubectl: unhandled ' + line + '\\n'); process.exit(9)
}
`

async function setup(env = {}) {
  const dir = await mkdtemp(path.join(tmpdir(), 'unseal-vault-'))
  await writeFile(path.join(dir, 'kubectl'), KUBECTL.trimStart(), 'utf8')
  await chmod(path.join(dir, 'kubectl'), 0o755)
  return {
    dir,
    env: {
      FAKE_DIR: dir,
      // The fake dir first, node for the fakes' shebang, and the system's own tools; no vault CLI.
      PATH: [dir, path.dirname(process.execPath), '/usr/bin', '/bin'].join(path.delimiter),
      ...env,
    },
  }
}

function run(env, input) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', [SCRIPT], { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.on('error', reject)
    child.on('close', (exitCode) => resolve({ exitCode, stdout, stderr }))
    child.stdin.on('error', (error) => { if (error.code !== 'EPIPE') reject(error) })
    child.stdin.end(input)
  })
}

const log = async (dir) => readFile(path.join(dir, 'kubectl.log'), 'utf8')

test('the unseal script finds Vault wherever its pod runs, whatever the pod is called', async () => {
  const { dir, env } = await setup({ FAKE_PODS: 'secrets-system vault-75d9688698-8vt75\n' })
  const { exitCode, stdout } = await run(env, 'good-share-1\ngood-share-2\n')
  assert.equal(exitCode, 0, stdout)
  assert.match(stdout, /vault pod: secrets-system\/vault-75d9688698-8vt75/)
  assert.match(await log(dir), /exec -i pod\/vault-75d9688698-8vt75 -- vault operator unseal good-share-1/)
})

test('the unseal script says Vault is open only once it reads the seal state back as open', async () => {
  const { env } = await setup({ FAKE_PODS: 'secrets-system vault-abc\n' })
  const { exitCode, stdout } = await run(env, 'good-share-1\ngood-share-2\n')
  assert.equal(exitCode, 0)
  assert.match(stdout, /VAULT IS UNSEALED/)
})

test('the unseal script exits nonzero when the shares run out before Vault opens', async () => {
  const { env } = await setup({ FAKE_PODS: 'secrets-system vault-abc\n' })
  const { exitCode, stdout } = await run(env, 'good-share-1\n\n')
  assert.notEqual(exitCode, 0)
  assert.doesNotMatch(stdout, /VAULT IS UNSEALED/)
})

test('the unseal script starts the count again after a share Vault rejects', async () => {
  const { env } = await setup({ FAKE_PODS: 'secrets-system vault-abc\n' })
  const { exitCode, stdout } = await run(env, 'good-share-1\nwrong-share\ngood-share-1\ngood-share-2\n')
  assert.equal(exitCode, 0, stdout)
  assert.match(stdout, /that share was REJECTED/)
})

test('the unseal script asks for no share when Vault is already open', async () => {
  const { dir, env } = await setup({ FAKE_PODS: 'secrets-system vault-abc\n', FAKE_OPEN: '1' })
  const { exitCode, stdout } = await run(env, '')
  assert.equal(exitCode, 0)
  assert.match(stdout, /already unsealed/)
  assert.doesNotMatch(await log(dir), /operator unseal/)
})

test('the unseal script stops without asking for a share when no pod carries the label', async () => {
  const { dir, env } = await setup({ FAKE_PODS: '' })
  const { exitCode, stderr } = await run(env, 'good-share-1\n')
  assert.notEqual(exitCode, 0)
  assert.match(stderr, /expected exactly 1 running Vault pod, found 0/)
  assert.doesNotMatch(await log(dir), /exec/)
})

test('the unseal script names every candidate and stops when two pods carry the label', async () => {
  const { dir, env } = await setup({ FAKE_PODS: 'secrets-system vault-abc\ndata-system vault-0\n' })
  const { exitCode, stderr } = await run(env, 'good-share-1\n')
  assert.notEqual(exitCode, 0)
  assert.match(stderr, /secrets-system vault-abc/)
  assert.match(stderr, /data-system vault-0/)
  assert.doesNotMatch(await log(dir), /exec/)
})

test('the unseal script goes straight to the pod VAULT_NS and VAULT_POD name', async () => {
  const { dir, env } = await setup({ FAKE_PODS: '', VAULT_NS: 'data-system', VAULT_POD: 'vault-0' })
  const { exitCode, stdout } = await run(env, 'good-share-1\ngood-share-2\n')
  assert.equal(exitCode, 0, stdout)
  const calls = await log(dir)
  assert.doesNotMatch(calls, /get pods/)
  assert.match(calls, /-n data-system exec -i pod\/vault-0/)
})
