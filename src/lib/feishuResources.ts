export const FEISHU_BASE_URL = 'https://yal2at57cvq.feishu.cn/base/GtSLbyyR3aCENOsJYC6cdlsVnih';
export const EXPERIENCE_DOCUMENT_URL = 'https://yal2at57cvq.feishu.cn/docx/UHNMd1JBWonKQFxONCecVMFfnNG';

export interface SourceExperience {
  id: string;
  category: 'company';
  group: string;
  title: string;
  company: string;
  role: string;
  intent: string;
  keyPoints: string[];
  answer: string;
  source: string;
}
export interface ExperienceBlock { order: number; recordId: string; type: string; text: string }
export interface FeishuResource {
  resource_id: 'company-catalog' | 'interview-experiences';
  status: 'success' | 'error';
  checked_at: string;
  last_success_at: string | null;
  error_code: string | null;
  source_url: string;
  data: { articles?: SourceExperience[]; sourceModifiedAt?: string; sourceHash?: string };
}

export function cleanSourceText(value: string) {
  return value.replace(/[\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/gu, '').replace(/\r\n?/gu, '\n').trim();
}

const COMPANIES = ['中国邮政储蓄银行', '邮储银行', '农业银行', '普华永道', 'pwc普华永道', '阿里巴巴', '阿里淘宝', '阿里', '字节跳动', '字节', '网易互娱', '网易游戏', '网易', '美团', '滴滴', 'Anker', '米哈游', '叠纸游戏', '360集团', '雀巢', '科大讯飞', 'B站', '同花顺', '唯品会', '三七互娱', '锐捷网络', '华为', '贝壳找房', '快手', '拼多多', '良品铺子', '小米', '搜狐', '安永', '德勤', 'DTT德勤', '立信', '京东', '携程', '小红书', '顺丰', '壳牌', '抖音', '英雄互娱', '腾讯', '卡夫亨氏', '陶氏化学', '阅文集团', '中信', 'EY安永', 'EY', 'oppo', '去哪儿网', '逸仙电商', '丰巢', 'TME', 'IEG'];

export function parseExperienceBlocks(blocks: ExperienceBlock[]): SourceExperience[] {
  const articles: SourceExperience[] = [];
  let current: SourceExperience | undefined;
  for (const block of [...blocks].sort((a, b) => a.order - b.order)) {
    const text = cleanSourceText(block.text);
    if (!text) continue;
    if (block.type === 'heading2') {
      const title = text.replace(/^面经分享[\s·•:：]+/u, '').trim();
      if (!/^[A-Za-z0-9_-]{5,80}$/u.test(block.recordId) || !title) throw new Error('INVALID_EXPERIENCE_HEADING');
      const company = [...COMPANIES].sort((a, b) => b.length - a.length).find((name) => title.toLowerCase().startsWith(name.toLowerCase())) || title.split(/\s+/u)[0];
      current = { id: `feishu-${block.recordId}`, category: 'company', group: '公司岗位面经', title, company,
        role: title.slice(company.length).trim(), intent: '', keyPoints: [], answer: '', source: '《面经分享》' };
      articles.push(current);
    } else if (current) {
      current.answer += `${current.answer ? '\n\n' : ''}${text}`;
    }
  }
  return validateSourceExperiences(articles);
}

export function validateSourceExperiences(value: unknown): SourceExperience[] {
  if (!Array.isArray(value) || !value.length || value.length > 1000) throw new Error('INVALID_EXPERIENCE_COUNT');
  const ids = new Set<string>();
  return value.map((item: Record<string, unknown>) => {
    if (!item || typeof item !== 'object' || typeof item.id !== 'string' || !/^feishu-[A-Za-z0-9_-]{5,80}$/u.test(item.id)
      || ids.has(item.id) || typeof item.title !== 'string' || !item.title.trim() || item.title.length > 300
      || typeof item.answer !== 'string' || !item.answer.trim() || item.answer.length > 100_000) throw new Error('INVALID_EXPERIENCE_BODY');
    ids.add(item.id);
    return { id: item.id, category: 'company', group: '公司岗位面经', title: cleanSourceText(item.title),
      company: typeof item.company === 'string' ? item.company.slice(0, 300) : '', role: typeof item.role === 'string' ? item.role.slice(0, 300) : '',
      intent: '', keyPoints: [], answer: cleanSourceText(item.answer), source: '《面经分享》' };
  });
}
