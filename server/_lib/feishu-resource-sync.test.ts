import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { handleResourceSync } from './feishu-resource-sync';
const keys = generateKeyPairSync('ed25519');
const env = { supabaseUrl: 'https://test.invalid', serviceRoleKey: 'test', publicKey: keys.publicKey.export({ format: 'jwk' }).x! };
const article = { id: 'feishu-recordOne', title: '测试公司运营一面', answer: '先自我介绍，再说明项目经历。' };
function request(extra: Record<string, unknown>, old = false) {
  const body = JSON.stringify({ resource_id: 'interview-experiences', action: 'apply', articles: [article], sourceHash: 'a'.repeat(64), ...extra });
  const timestamp = String(Date.now() - (old ? 130_000 : 0));
  return new Request('https://test.invalid', { method: 'POST', body, headers: { 'x-catalog-timestamp': timestamp, 'x-catalog-signature': sign(null, Buffer.from(`${timestamp}\n${body}`), keys.privateKey).toString('base64url') } });
}
test('rejects unsigned and expired resource writes without accessing the database', async () => {
  let reads = 0;
  const db = (async () => { reads++; return Response.json([]); }) as typeof fetch;
  assert.equal((await handleResourceSync(new Request('https://test.invalid', { method: 'POST', body: '{}' }), env, db)).status, 401);
  assert.equal((await handleResourceSync(request({}, true), env, db)).status, 401);
  assert.equal(reads, 0);
});
test('incomplete and invalid snapshots never replace successful content', async () => {
  const db = (async (_input, init) => { assert.notEqual(init?.method, 'POST'); return Response.json([{ data: { articles: Array(10).fill(article) } }]); }) as typeof fetch;
  assert.equal((await handleResourceSync(request({}), env, db)).status, 400);
  assert.equal((await handleResourceSync(request({ articles: [] }), env, db)).status, 400);
});
test('success writes one atomic snapshot, and failure preserves its data and success date', async () => {
  const writes: Record<string, unknown>[] = [];
  const db = (async (_input, init) => { if (init?.method) { writes.push(JSON.parse(String(init.body))); return new Response(null, { status: 204 }); } return Response.json([]); }) as typeof fetch;
  assert.equal((await handleResourceSync(request({}), env, db)).status, 200);
  assert.ok(writes[0].data);
  assert.ok(writes[0].last_success_at);
  assert.equal((await handleResourceSync(request({ action: 'failure' }), env, db)).status, 200);
  assert.equal(writes[1].status, 'error');
  assert.equal(writes[1].data, undefined);
  assert.equal(writes[1].last_success_at, undefined);
});
