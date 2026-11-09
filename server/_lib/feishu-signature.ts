import { CATALOG_SYNC_PUBLIC_KEY } from './catalog-sync-public-key';

function base64Bytes(value: string) {
  return Uint8Array.from(atob(value.replace(/-/gu, '+').replace(/_/gu, '/')), (char) => char.charCodeAt(0));
}
export async function verifyCatalogSignature(request: Request, body: string, publicKey = CATALOG_SYNC_PUBLIC_KEY, now = Date.now()) {
  const timestamp = request.headers.get('x-catalog-timestamp') || '';
  const signature = request.headers.get('x-catalog-signature') || '';
  if (!/^\d{13}$/u.test(timestamp) || Math.abs(now - Number(timestamp)) > 120_000 || !/^[A-Za-z0-9_-]{86}$/u.test(signature)) return false;
  try {
    const key = await crypto.subtle.importKey('raw', base64Bytes(publicKey), { name: 'Ed25519' }, false, ['verify']);
    return crypto.subtle.verify('Ed25519', key, base64Bytes(signature), new TextEncoder().encode(`${timestamp}\n${body}`));
  } catch { return false; }
}
