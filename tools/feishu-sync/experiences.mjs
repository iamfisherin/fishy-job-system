import { chromium } from 'playwright';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { SOURCE_URL, saveCloudSession, navigateSource, cloudSessionState } from './probe.mjs';
import { cleanSourceText, parseExperienceBlocks } from '../../src/lib/feishuResources.ts';

const dir = process.env.FEISHU_SYNC_STATE_DIR || join(homedir(), '.sugar-job-system', 'feishu-sync');
const output = join(dir, 'output');
await mkdir(output, { recursive: true });
const storageState = cloudSessionState(process.env.FEISHU_AUTH_STATE
  ? JSON.parse(await readFile(process.env.FEISHU_AUTH_STATE, 'utf8'))
  : process.env.FEISHU_SESSION_GZIP_B64
    ? JSON.parse(gunzipSync(Buffer.from(process.env.FEISHU_SESSION_GZIP_B64, 'base64')).toString('utf8'))
    : JSON.parse(await readFile(join(dir, 'session-state.json'), 'utf8')));
const browser = await chromium.launch({ ...(process.env.FEISHU_BROWSER_CHANNEL === 'chromium' ? {} : { channel: process.env.FEISHU_BROWSER_CHANNEL || (process.platform === 'win32' ? 'chrome' : undefined) }), headless: true });
try {
  const context = await browser.newContext({ storageState, locale: 'zh-CN', viewport: { width: 1440, height: 960 } });
  const page = await context.newPage();
  await navigateSource(page, SOURCE_URL);
  // Resolve the current document through its named sidebar entry. Base's
  // embedded-document IDs change; the old shared table ID is no longer valid.
  await page.getByText('💎面经分享', { exact: true }).click({ timeout: 90_000 });
  const iframe = page.locator('iframe[src*="/docx/"]').first();
  await iframe.waitFor({ state: 'attached', timeout: 90_000 });
  const target = new URL(await iframe.getAttribute('src'));
  if (target.origin !== 'https://yal2at57cvq.feishu.cn' || !/^\/docx\/[A-Za-z0-9]+$/u.test(target.pathname)) throw new Error('INVALID_EXPERIENCE_SOURCE');
  const sourceUrl = `${target.origin}${target.pathname}`;
  const doc = await context.newPage();
  await navigateSource(doc, sourceUrl);
  await doc.locator('.docx-page-block h1').waitFor({ timeout: 90_000 });
  if (cleanSourceText(await doc.locator('.docx-page-block h1').innerText()) !== '面经分享') throw new Error('WRONG_EXPERIENCE_DOCUMENT');
  const date = (await doc.locator('.docx-page-block').innerText()).match(/(\d{4})年(\d{1,2})月(\d{1,2})日修改/u);
  const sourceModifiedAt = date ? `${date[1]}-${date[2].padStart(2, '0')}-${date[3].padStart(2, '0')}` : '';
  const collected = new Map();
  let atBottom = 0;
  let complete = false;
  for (let step = 0; step < 1200; step++) {
    const snapshot = await doc.evaluate(() => {
      const scroller = document.querySelector('.bear-web-x-container');
      if (!scroller) throw new Error('EXPERIENCE_SCROLLER_MISSING');
      const blocks = [...document.querySelectorAll('.docx-page-block [data-block-type][data-record-id]')].map((element) => ({
        order: Number(element.getAttribute('data-block-id')), recordId: element.getAttribute('data-record-id'),
        type: element.getAttribute('data-block-type'), text: element.innerText || '',
      }));
      const bottom = scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2;
      scroller.scrollTop += scroller.clientHeight * 0.65;
      return { blocks, bottom, height: scroller.scrollHeight };
    });
    const before = collected.size;
    for (const block of snapshot.blocks) collected.set(block.recordId, block);
    atBottom = snapshot.bottom && before === collected.size ? atBottom + 1 : 0;
    if (atBottom >= 3) { complete = true; break; }
    await doc.waitForTimeout(220);
  }
  const blocks = [...collected.values()].sort((a, b) => a.order - b.order);
  // Feishu virtualizes the body. A single DOM snapshot silently omits most
  // interviews; contiguous block numbers prove the entire scroll was captured.
  if (!complete || !blocks.length || blocks.some((block, index) => !Number.isInteger(block.order) || (index > 0 && block.order !== blocks[index - 1].order + 1))) throw new Error('INCOMPLETE_EXPERIENCE_DOCUMENT');
  const articles = parseExperienceBlocks(blocks);
  if (articles.length < 10) throw new Error('EXPERIENCE_SOURCE_TOO_SMALL');
  const sourceHash = createHash('sha256').update(JSON.stringify(articles)).digest('hex');
  await writeFile(join(output, 'experiences.json'), JSON.stringify({ articles, sourceUrl, sourceModifiedAt, sourceHash, checkedAt: new Date().toISOString(), blockCount: blocks.length }, null, 2), { mode: 0o600 });
  if (process.env.FEISHU_REFRESH_SESSION === '1') await saveCloudSession(context, dir);
  console.log(JSON.stringify({ articles: articles.length, blockCount: blocks.length, sourceModifiedAt, sourceHash }));
} finally { await browser.close(); }
