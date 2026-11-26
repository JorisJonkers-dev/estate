// The key test of litellm-catalog-keys.sh (ops/lib/litellm-keys.sh) tries each provider key the way
// the catalogue sync lists the provider, and sorts the answer into what to do next: ok, unproven,
// unauthorized, no-credit, rate-limited, wrong-base, server-error, network, needs-extra-field.
// These tests run the library against a local fake provider, with `curl` wrapped on PATH so every
// curl argument list is logged: a key must reach the provider in a header and never in an argument.
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn, execFileSync } from 'node:child_process'
import { createServer } from 'node:http'
import { chmod, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// Run with `node --test ops/test-litellm-catalog-keys.mjs`; it needs bash 4+, curl and jq.
const HERE = path.dirname(fileURLToPath(import.meta.url))
const LIB = path.join(HERE, 'lib', 'litellm-keys.sh')
const REGISTRY = path.join(HERE, 'litellm-providers.json')
const BASH = ['/opt/homebrew/bin/bash', '/usr/local/bin/bash', '/bin/bash']
  .find((b) => { try { return Number(execFileSync(b, ['-c', 'echo ${BASH_VERSINFO[0]}']).toString()) >= 4 } catch { return false } })

const GOOD = 'good-key-0123456789'
const json = (res, code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)) }

// The fake provider. Each path prefix behaves like one kind of provider.
function provider() {
  const seen = []
  const server = createServer((req, res) => {
    let body = ''
    req.on('data', (c) => { body += c })
    req.on('end', () => {
      seen.push({ method: req.method, url: req.url, headers: req.headers, body })
      const auth = req.headers.authorization || ''
      const u = req.url
      if (u === '/ok/models') return auth === `Bearer ${GOOD}` ? json(res, 200, { data: [{ id: 'a' }, { id: 'b' }, { id: 'c' }] }) : json(res, 401, { error: { message: 'Invalid API Key' } })
      if (u === '/xkey/models') return req.headers['x-api-key'] === GOOD && req.headers['anthropic-version'] ? json(res, 200, { data: [{ id: 'a' }] }) : json(res, 401, { error: { message: 'invalid x-api-key' } })
      if (u === '/public/models') return json(res, 200, { data: [{ id: 'a' }] })
      if (u === '/public/key') return auth === `Bearer ${GOOD}` ? json(res, 200, { data: {} }) : json(res, 401, { error: { message: 'No auth credentials found' } })
      if (u === '/public/chat/completions') return auth === `Bearer ${GOOD}` ? json(res, 200, { choices: [] }) : json(res, 403, { detail: 'Authorization failed' })
      if (u === '/bare/models') return json(res, 200, [{ id: 'a' }, { id: 'b' }])
      if (u === '/limited/models') return json(res, 429, { error: { message: 'Rate limit reached' } })
      if (u === '/broke/models') return json(res, 402, { error: { message: 'Insufficient credits' } })
      if (u === '/gone/models') return json(res, 404, { error: { message: 'Not Found' } })
      if (u === '/html/models') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end('<html>login</html>') }
      if (u === '/down/models') return json(res, 503, { error: { message: 'overloaded' } })
      if (u === '/cf/accounts') return auth === `Bearer ${GOOD}` ? json(res, 200, { result: [] }) : json(res, 401, { errors: [{ message: 'Invalid API Token' }] })
      if (u.startsWith('/cf/accounts/0123/ai/models/search')) return auth === `Bearer ${GOOD}` ? json(res, 200, { result: [{}], result_info: { total_count: 7 } }) : json(res, 403, {})
      if (u === '/iam') return body.includes(`apikey=${GOOD}`) ? json(res, 200, { access_token: 'iam-token' }) : json(res, 400, { errorCode: 'BXNIM0415E', errorMessage: 'Provided API key could not be found.' })
      if (u.startsWith('/wx/ml/v1/foundation_model_specs')) return auth === 'Bearer iam-token' ? json(res, 200, { total_count: 5, resources: [] }) : json(res, 401, {})
      if (u === '/gh/repos/o/r') return auth === `Bearer ${GOOD}` ? json(res, 200, { full_name: 'o/r' }) : json(res, 404, { message: 'Not Found' })
      json(res, 500, { error: { message: `unhandled ${u}` } })
    })
  })
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, seen, base: `http://127.0.0.1:${server.address().port}` })))
}

const bearer = (id, base, test = {}, fields = []) => ({
  id, name: id, steps: [], fields: [{ name: `${id}_key`, secret: true }, ...fields], test: { kind: 'bearer', base, ...test },
})

async function setup(base) {
  const dir = await mkdtemp(path.join(tmpdir(), 'litellm-keys-'))
  const registry = {
    class_help: { unauthorized: ['make a new key'] },
    providers: [
      bearer('ok', `${base}/ok`),
      bearer('xkey', `${base}/xkey`, { auth: 'x-api-key', headers: { 'anthropic-version': '2023-06-01' } }),
      bearer('public', `${base}/public`),
      bearer('publickey', `${base}/public`, { auth_path: '/key' }),
      bearer('publicprobe', `${base}/public`, { probe_model: 'm' }),
      bearer('bare', `${base}/bare`, { count: 'length' }),
      bearer('limited', `${base}/limited`),
      bearer('broke', `${base}/broke`),
      bearer('gone', `${base}/gone`),
      bearer('html', `${base}/html`),
      bearer('down', `${base}/down`),
      bearer('closed', 'http://127.0.0.1:9'),
      bearer('needsbase', '', { base_field: 'needsbase_base' }, [{ name: 'needsbase_base', secret: false, required: true }]),
      bearer('needsextra', `${base}/ok`, {}, [{ name: 'needsextra_project', secret: false, required: true }]),
      { id: 'cf', name: 'cf', steps: [], fields: [{ name: 'cf_key', secret: true }, { name: 'cloudflare_account_id', secret: false }], test: { kind: 'cloudflare', base: `${base}/cf` } },
      { id: 'wx', name: 'wx', steps: [], fields: [{ name: 'wx_key', secret: true }, { name: 'wx_base', secret: false, required: true }], test: { kind: 'watsonx', iam: `${base}/iam`, base_field: 'wx_base', path: '/ml/v1/foundation_model_specs?version=2024-05-01', count: '.total_count' } },
      { id: 'gh', name: 'gh', steps: [], fields: [{ name: 'gh_key', secret: true }], test: { kind: 'github', base: `${base}/gh`, repo: 'o/r' } },
    ],
  }
  await writeFile(path.join(dir, 'registry.json'), JSON.stringify(registry), 'utf8')
  // curl on PATH logs its arguments, then runs the real one.
  const realCurl = execFileSync('/bin/sh', ['-c', 'command -v curl']).toString().trim()
  await writeFile(path.join(dir, 'curl'), `#!/bin/sh\nprintf '%s\\n' "$*" >>"${dir}/curl.argv"\nexec "${realCurl}" "$@"\n`, 'utf8')
  await chmod(path.join(dir, 'curl'), 0o755)
  return dir
}

// lkTest runs lk_test for one provider with the given Vault values and returns {cls, detail, out}.
function lkTest(dir, id, values) {
  const assigns = Object.entries(values).map(([k, v]) => `LK_VAL[${k}]=${JSON.stringify(v)}`).join('\n')
  const script = `set -euo pipefail\nsource ${JSON.stringify(LIB)}\nLK_WORK=$(mktemp -d)\n${assigns}\nlk_test ${id}\nprintf '%s\\t%s\\n' "$LK_CLASS" "$LK_DETAIL"\nls "$LK_WORK" | grep '^h\\.' && echo LEFTOVER || true\n`
  return new Promise((resolve, reject) => {
    const child = spawn(BASH, ['-c', script], {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, LITELLM_PROVIDERS: path.join(dir, 'registry.json'), LK_TIMEOUT: '5' },
    })
    let out = ''; let err = ''
    child.stdout.on('data', (c) => { out += c })
    child.stderr.on('data', (c) => { err += c })
    child.on('error', reject)
    child.on('close', (code) => {
      if (code !== 0) return reject(new Error(`exit ${code}: ${err}`))
      const [cls, detail] = out.trim().split('\n')[0].split('\t')
      resolve({ cls, detail, out, err })
    })
  })
}

let fake
let dir
test.before(async () => { fake = await provider(); dir = await setup(fake.base) })
test.after(() => fake.server.close())

const cases = [
  ['a key the list accepts is ok, with its model count', 'ok', { ok_key: GOOD }, 'ok', /^3 models/],
  ['a key the provider refuses is unauthorized, with its message', 'ok', { ok_key: 'bad' }, 'unauthorized', /401 Invalid API Key/],
  ['Anthropic-style keys go in x-api-key beside the version header', 'xkey', { xkey_key: GOOD }, 'ok', /1 models/],
  ['a list that answers without a key leaves the key unproven', 'public', { public_key: 'bad' }, 'unproven', /without a key/],
  ['an auth endpoint proves a key a public list cannot', 'publickey', { publickey_key: 'bad' }, 'unauthorized', /\/key/],
  ['a passing auth endpoint keeps ok', 'publickey', { publickey_key: GOOD }, 'ok', /models/],
  ['a one-token probe proves a key a public list cannot', 'publicprobe', { publicprobe_key: 'bad' }, 'unauthorized', /probe of m/],
  ['a bare JSON list counts too (Together)', 'bare', { bare_key: GOOD }, 'unproven', /2 models/],
  ['429 is rate-limited', 'limited', { limited_key: GOOD }, 'rate-limited', /429/],
  ['402 is no-credit', 'broke', { broke_key: GOOD }, 'no-credit', /Insufficient/],
  ['404 is wrong-base', 'gone', { gone_key: GOOD }, 'wrong-base', /404/],
  ['a 200 that is no model list is wrong-base', 'html', { html_key: GOOD }, 'wrong-base', /no model list/],
  ['5xx is server-error', 'down', { down_key: GOOD }, 'server-error', /503/],
  ['no answer at all is network', 'closed', { closed_key: GOOD }, 'network', /no answer/],
  ['an empty key is missing and nothing is asked', 'ok', {}, 'missing', /no ok_key/],
  ['a base kept in an empty Vault field needs that field', 'needsbase', { needsbase_key: GOOD }, 'needs-extra-field', /needsbase_base/],
  ['a base in a Vault field is used', 'needsbase', { needsbase_key: GOOD, needsbase_base: 'BASE/ok/' }, 'ok', /3 models/],
  ['an accepted key with a required field empty needs that field', 'needsextra', { needsextra_key: GOOD }, 'needs-extra-field', /needsextra_project is empty/],
  ['Cloudflare with no account id and a token that sees 0 accounts needs the id', 'cf', { cf_key: GOOD }, 'needs-extra-field', /sees 0 accounts/],
  ['Cloudflare with the account id lists the account\'s models', 'cf', { cf_key: GOOD, cloudflare_account_id: '0123' }, 'ok', /7 models/],
  ['Cloudflare refusing the token is unauthorized', 'cf', { cf_key: 'bad' }, 'unauthorized', /accounts/],
  ['watsonx exchanges the key at IAM and lists the region', 'wx', { wx_key: GOOD, wx_base: '' }, 'needs-extra-field', /IAM/],
  ['watsonx with its base lists foundation models', 'wx', { wx_key: GOOD, wx_base: 'BASE/wx' }, 'ok', /5 models/],
  ['watsonx with a key IAM does not know is unauthorized', 'wx', { wx_key: 'bad', wx_base: 'BASE/wx' }, 'unauthorized', /IAM/],
  ['a GitHub token that cannot see its repository is unauthorized', 'gh', { gh_key: 'bad' }, 'unauthorized', /403/],
  ['a GitHub token that sees its repository is ok', 'gh', { gh_key: GOOD }, 'ok', /sees o\/r/],
]

for (const [name, id, values, cls, detail] of cases) {
  test(name, async () => {
    const v = Object.fromEntries(Object.entries(values).map(([k, x]) => [k, x.replace('BASE', fake.base)]))
    const r = await lkTest(dir, id, v)
    assert.equal(r.cls, cls, r.out + r.err)
    assert.match(r.detail, detail)
    assert.doesNotMatch(r.out, /LEFTOVER/, 'header and body files are removed after each request')
  })
}

test('no key ever reaches curl as an argument, and no output shows one', async () => {
  for (const id of ['ok', 'xkey', 'publicprobe', 'cf', 'wx', 'gh']) {
    const r = await lkTest(dir, id, { [`${id}_key`]: GOOD, cloudflare_account_id: '0123', wx_base: `${fake.base}/wx` })
    assert.doesNotMatch(r.out + r.err, new RegExp(GOOD))
  }
  const argv = await readFile(path.join(dir, 'curl.argv'), 'utf8')
  assert.doesNotMatch(argv, new RegExp(GOOD))
  assert.doesNotMatch(argv, /iam-token/)
  assert.ok(fake.seen.some((r) => r.headers.authorization === `Bearer ${GOOD}`), 'the key did reach the provider in a header')
})

test('lk_classify sorts status codes the same way for every provider', async () => {
  const body = path.join(dir, 'body.json')
  const run = async (code, text) => {
    await writeFile(body, text, 'utf8')
    return execFileSync(BASH, ['-c', `source ${JSON.stringify(LIB)}; lk_classify ${code} ${JSON.stringify(body)} '.data | length'`]).toString().split('\t')[0]
  }
  assert.equal(await run(200, '{"data":[]}'), 'ok')
  assert.equal(await run(403, '{"error":{"message":"Your credit balance is too low"}}'), 'no-credit')
  assert.equal(await run(403, '{"error":{"message":"Forbidden"}}'), 'unauthorized')
  assert.equal(await run(405, ''), 'wrong-base')
  assert.equal(await run('000', ''), 'network')
})

test('the provider registry is well formed and every provider says where to make its key', () => {
  execFileSync(BASH, ['-c', `source ${JSON.stringify(LIB)}; lk_registry_check`], { env: { ...process.env, LITELLM_PROVIDERS: REGISTRY } })
  return readFile(REGISTRY, 'utf8').then((text) => {
    const { providers } = JSON.parse(text)
    for (const p of providers) {
      assert.ok(p.steps.length > 0, `${p.id} has steps`)
      if (p.id !== 'local') assert.match(p.key_url ?? '', /^https:\/\//, `${p.id} has a key page`)
      assert.ok(['bearer', 'cloudflare', 'watsonx', 'github'].includes(p.test.kind), `${p.id} has a known test kind`)
      assert.ok(p.test.base || p.test.base_field || p.test.kind === 'github', `${p.id} has a base`)
    }
    // OpenRouter is tested, never offered as a new account.
    assert.equal(providers.find((p) => p.id === 'openrouter').signup_url, undefined)
  })
})
