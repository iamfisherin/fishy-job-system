import test from 'node:test';
import assert from 'node:assert/strict';
import { parseExperienceBlocks, validateSourceExperiences } from './feishuResources';

const blocks = [
  { order: 2, recordId: 'headingA', type: 'heading2', text: '面经分享·美团 产品运营一面\u200b' },
  { order: 3, recordId: 'bodyAAAA', type: 'text', text: '自我介绍\u200b' },
  { order: 4, recordId: 'bodyBBBB', type: 'text', text: '说明项目中的具体职责' },
  { order: 5, recordId: 'headingB', type: 'heading2', text: '网易互娱游戏生态运营hr面' },
  { order: 6, recordId: 'bodyCCCC', type: 'text', text: '为什么选择这个岗位？' },
];
test('extracts source bodies in document order without table-of-contents duplicates', () => {
  const result = parseExperienceBlocks([...blocks].reverse());
  assert.equal(result.length, 2);
  assert.equal(result[0].company, '美团');
  assert.equal(result[0].answer, '自我介绍\n\n说明项目中的具体职责');
  assert.equal(result[1].title, '网易互娱游戏生态运营hr面');
  assert.equal(result[1].company, '网易互娱');
});
test('source record IDs survive text edits and distinguish interviews with identical titles', () => {
  const before = parseExperienceBlocks(blocks);
  const after = parseExperienceBlocks(blocks.map((b) => b.order === 3 ? { ...b, text: '补充了面试问题' } : b));
  assert.equal(after[0].id, before[0].id);
  assert.notEqual(after[0].answer, before[0].answer);
});
test('separates a company name from an unspaced company and role heading', () => {
  const result = parseExperienceBlocks([{ ...blocks[0], text: '面经分享·腾讯IEG消费互联网营销一面二面' }, blocks[1]]);
  assert.equal(result[0].company, '腾讯');
  assert.equal(result[0].role, 'IEG消费互联网营销一面二面');
});
test('rejects empty, partial and duplicate-ID snapshots', () => {
  assert.throws(() => parseExperienceBlocks([blocks[0]]), /INVALID_EXPERIENCE_BODY/u);
  assert.throws(() => validateSourceExperiences([]), /INVALID_EXPERIENCE_COUNT/u);
  const article = parseExperienceBlocks(blocks)[0];
  assert.throws(() => validateSourceExperiences([article, article]), /INVALID_EXPERIENCE_BODY/u);
});
