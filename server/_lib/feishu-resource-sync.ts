import { verifyCatalogSignature } from './feishu-signature';
import { EXPERIENCE_DOCUMENT_URL, FEISHU_BASE_URL, validateSourceExperiences } from '../../src/lib/feishuResources';

const MAX_BYTES = 2 * 1024 * 1024;
type Environment = { supabaseUrl: string; serviceRoleKey: string; publicKey?: string };
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status,
  headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } });

export async function handleResourceSync(request: Request, env: Environment, fetcher: typeof fetch = fetch) {
  if (request.method !== 'POST') return reply({ error: 'METHOD_NOT_ALLOWED' }, 405);
  if (Number(request.headers.get('content-length')) > MAX_BYTES) return reply({ error: 'PAYLOAD_TOO_LARGE' }, 413);
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_BYTES) return reply({ error: 'PAYLOAD_TOO_LARGE' }, 413);
  if (!await verifyCatalogSignature(request, raw, env.publicKey)) return reply({ error: 'UNAUTHORIZED' }, 401);
  try {
    const body = JSON.parse(raw) as Record<string, unknown>;
    const id = body.resource_id;
    if (!['company-catalog', 'interview-experiences'].includes(String(id)) || !['apply', 'preview', 'failure'].includes(String(body.action))) return reply({ error: 'INVALID_RESOURCE' }, 400);
    if (!env.supabaseUrl || !env.serviceRoleKey) throw new Error('DATABASE_NOT_CONFIGURED');
    const db = async (path: string, init?: RequestInit) => {
      const response = await fetcher(`${env.supabaseUrl.replace(/\/$/u, '')}/rest/v1/${path}`, { ...init,
        headers: { apikey: env.serviceRoleKey, authorization: `Bearer ${env.serviceRoleKey}`, ...init?.headers }, signal: AbortSignal.timeout(30_000) });
      if (!response.ok) throw new Error(`DATABASE_${response.status}`);
      return response;
    };
    const now = new Date().toISOString();
    let source = id === 'interview-experiences' ? EXPERIENCE_DOCUMENT_URL : FEISHU_BASE_URL;
    if (id === 'interview-experiences' && typeof body.sourceUrl === 'string') {
      const discovered = new URL(body.sourceUrl);
      if (discovered.origin !== 'https://yal2at57cvq.feishu.cn' || !/^\/docx\/[A-Za-z0-9]+$/u.test(discovered.pathname)) return reply({ error: 'INVALID_SOURCE_URL' }, 400);
      source = `${discovered.origin}${discovered.pathname}`;
    }
    if (body.action === 'failure') {
      // PATCH preserves the last successful content and timestamp.
      await db(`feishu_sync_resources?resource_id=eq.${id}`, { method: 'PATCH', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ status: 'error', checked_at: now, error_code: 'FEISHU_SYNC_FAILED' }) });
      return reply({ ok: true, status: 'error' });
    }
    let data: Record<string, unknown> = {};
    if (id === 'interview-experiences') {
      const articles = validateSourceExperiences(body.articles);
      if (!/^[a-f0-9]{64}$/u.test(String(body.sourceHash))) return reply({ error: 'INVALID_SOURCE_HASH' }, 400);
      const previous = await (await db(`feishu_sync_resources?resource_id=eq.${id}&select=data`)).json() as Array<{ data: { articles?: unknown[] } }>;
      const previousCount = previous[0]?.data.articles?.length || 0;
      if (articles.length < previousCount * 0.7) return reply({ error: 'INCOMPLETE_EXPERIENCE_SOURCE' }, 400);
      data = { articles, sourceHash: body.sourceHash,
        sourceModifiedAt: /^\d{4}-\d{2}-\d{2}$/u.test(String(body.sourceModifiedAt)) ? body.sourceModifiedAt : '' };
    }
    if (body.action === 'preview') return reply({ ok: true, count: Array.isArray(data.articles) ? data.articles.length : 0 });
    await db('feishu_sync_resources?on_conflict=resource_id', { method: 'POST',
      headers: { 'content-type': 'application/json', prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify({ resource_id: id, source_url: source, status: 'success', checked_at: now, last_success_at: now, error_code: null, data }) });
    return reply({ ok: true, checkedAt: now, count: Array.isArray(data.articles) ? data.articles.length : 0 });
  } catch (error) {
    const message = error instanceof Error && /^[A-Z0-9_]+$/u.test(error.message) ? error.message : 'RESOURCE_SYNC_FAILED';
    return reply({ error: message }, message.startsWith('INVALID_') ? 400 : 503);
  }
}
