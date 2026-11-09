import type { FeishuResource } from '../lib/feishuResources';

export default function FeishuSyncStatus({ resource, error, weekly = false }: { resource: FeishuResource | null; error: boolean; weekly?: boolean }) {
  const stale = resource?.last_success_at ? Date.now() - Date.parse(resource.last_success_at) > (weekly ? 9 : 2) * 86_400_000 : false;
  const failed = resource?.status === 'error' || stale;
  const last = resource?.last_success_at ? new Intl.DateTimeFormat('zh-CN', { timeZone: 'America/New_York', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(resource.last_success_at)) : null;
  return <div role="status" style={{ color: failed || error ? '#a65a3c' : 'var(--sugar-ink-tertiary)', fontSize: 11.5, lineHeight: 1.6, marginTop: 8 }}>
    {weekly ? '每周一同步' : '每日同步'} · {failed ? '同步异常，保留上次资料' : error ? '同步状态暂不可用' : last ? '最近成功' : '等待同步状态'}{last ? ` ${last}（美东）` : ''}
    {weekly && resource?.data.sourceModifiedAt && <span style={{ display: 'block' }}>原文修改日期：{resource.data.sourceModifiedAt}</span>}
  </div>;
}
