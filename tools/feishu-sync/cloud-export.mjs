import { gunzipSync } from 'node:zlib';
import { writeFile } from 'node:fs/promises';
import { main, cloudSessionState } from './probe.mjs';

try { await main('export'); }
catch (error) {
  if (!process.env.FEISHU_AUTH_STATE || !process.env.FEISHU_SESSION_GZIP_B64) throw error;
  // A public document can issue an anonymous session. Never let that replace
  // the user-granted bootstrap login; retry once from the original grant.
  console.warn('Cached session could not export; retrying the original user-authorized login.');
  const state = cloudSessionState(JSON.parse(gunzipSync(Buffer.from(process.env.FEISHU_SESSION_GZIP_B64, 'base64')).toString('utf8')));
  await writeFile(process.env.FEISHU_AUTH_STATE, JSON.stringify(state), { mode: 0o600 });
  await main('export');
}
