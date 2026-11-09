import { useCallback, useEffect, useRef, useState } from 'react';
import { isSupabaseConfigured, supabase } from '../lib/supabase';
import type { FeishuResource } from '../lib/feishuResources';

export function useFeishuResource(id: FeishuResource['resource_id']) {
  const [resource, setResource] = useState<FeishuResource | null>(null);
  const [error, setError] = useState(false);
  const inFlight = useRef<Promise<void> | null>(null);
  const refresh = useCallback(() => {
    if (inFlight.current) return inFlight.current;
    const request = (async () => {
      if (!isSupabaseConfigured) return;
      try {
        const result = await supabase.from('feishu_sync_resources').select('resource_id,status,checked_at,last_success_at,error_code,source_url,data').eq('resource_id', id).maybeSingle();
        if (result.error) throw result.error;
        setResource(result.data as FeishuResource | null);
        setError(false);
      } catch { setError(true); }
    })().finally(() => { inFlight.current = null; });
    inFlight.current = request;
    return request;
  }, [id]);
  useEffect(() => {
    void refresh();
    const visible = () => { if (document.visibilityState === 'visible') void refresh(); };
    const timer = window.setInterval(visible, 5 * 60_000);
    window.addEventListener('focus', visible);
    window.addEventListener('online', visible);
    document.addEventListener('visibilitychange', visible);
    return () => { window.clearInterval(timer); window.removeEventListener('focus', visible); window.removeEventListener('online', visible); document.removeEventListener('visibilitychange', visible); };
  }, [refresh]);
  return { resource, error };
}
