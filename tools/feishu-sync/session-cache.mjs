import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const AAD = Buffer.from('sugar-feishu-session-cache-v1');
export function sealSession(plaintext, key) {
  if (key.length !== 32) throw new Error('INVALID_SESSION_CIPHER_KEY');
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(AAD);
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return JSON.stringify({ v: 1, iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), body: body.toString('base64') });
}
export function openSession(envelope, key) {
  const data = JSON.parse(envelope);
  if (key.length !== 32 || data.v !== 1) throw new Error('INVALID_SESSION_CACHE');
  const cipher = createDecipheriv('aes-256-gcm', key, Buffer.from(data.iv, 'base64'));
  cipher.setAAD(AAD);
  cipher.setAuthTag(Buffer.from(data.tag, 'base64'));
  return Buffer.concat([cipher.update(Buffer.from(data.body, 'base64')), cipher.final()]);
}
async function main() {
  const dir = process.env.FEISHU_SYNC_STATE_DIR;
  const cache = process.env.FEISHU_SESSION_CACHE_DIR;
  if (!dir || !cache) throw new Error('SESSION_DIRECTORIES_MISSING');
  const key = Buffer.from(process.env.FEISHU_SESSION_CIPHER_KEY || '', 'base64');
  if (key.length !== 32) throw new Error('INVALID_SESSION_CIPHER_KEY');
  await mkdir(dir, { recursive: true });
  await mkdir(cache, { recursive: true });
  if (process.argv[2] === 'restore') {
    let state;
    try { state = openSession(await readFile(join(cache, 'session.enc'), 'utf8'), key); console.log('Restored encrypted refreshed session.'); }
    catch { state = gunzipSync(Buffer.from(process.env.FEISHU_SESSION_GZIP_B64 || '', 'base64')); console.log('Using the encrypted GitHub Secret bootstrap session.'); }
    const parsed = JSON.parse(state.toString('utf8'));
    if (!Array.isArray(parsed.cookies) || !Array.isArray(parsed.origins)) throw new Error('INVALID_SESSION_STATE');
    await writeFile(join(dir, 'session-state.json'), state, { mode: 0o600 });
  } else if (process.argv[2] === 'save') {
    const state = await readFile(join(dir, 'session-state.json'));
    await writeFile(join(cache, 'session.enc'), sealSession(state, key), { mode: 0o600 });
    console.log('Refreshed session encrypted for the next cloud run.');
  } else throw new Error('INVALID_SESSION_CACHE_COMMAND');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch((error) => { console.error(error.message); process.exitCode = 1; });
