import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { sealSession, openSession } from './session-cache.mjs';
test('session cache encrypts credentials and rejects tampering and the wrong key', () => {
  const key = randomBytes(32);
  const state = Buffer.from('{"cookies":[{"value":"private-test-session"}],"origins":[]}');
  const sealed = sealSession(state, key);
  assert.ok(!sealed.includes('private-test-session'));
  assert.deepEqual(openSession(sealed, key), state);
  assert.throws(() => openSession(sealed, randomBytes(32)));
  const changed = JSON.parse(sealed);
  const body = Buffer.from(changed.body, 'base64'); body[0] ^= 1; changed.body = body.toString('base64');
  assert.throws(() => openSession(JSON.stringify(changed), key));
});
