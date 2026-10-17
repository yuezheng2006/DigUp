const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'shell/ui/i18n.js'), 'utf8');
function context(language) {
  const context = vm.createContext({ navigator: { languages: [language] }, module: { exports: {} } });
  vm.runInContext(source, context);
  return context;
}
const zh = context('zh-CN'), en = context('en-US');
const i18n = zh.module.exports;
assert.equal(i18n.language(['fr-FR', 'zh-Hans']), 'zh-Hans');
assert.equal(i18n.language(['en-US', 'zh-CN']), 'en');
assert.equal(i18n.language(['fr-FR']), 'en');
assert.equal(vm.runInContext('t("Search")', zh), '搜索');
assert.equal(vm.runInContext('t("Search")', en), 'Search');
assert.equal(vm.runInContext('t("{0} files to search in {1}", 3, "文稿")', zh), '可在 文稿 中搜索 3 个文件');
assert.equal(i18n.translate('{0}: {1}', ['{1}', '中文 100%'], 'zh-Hans'), '{1}: 中文 100%');
assert.equal(i18n.translate('unknown {0}', ['<script>'], 'zh-Hans'), 'unknown <script>');
for (const [key, value] of Object.entries(i18n.chinese)) {
  assert.deepEqual([...key.matchAll(/\{\d+\}/g)].map(x => x[0]).sort(),
    [...value.matchAll(/\{\d+\}/g)].map(x => x[0]).sort(), key);
}
// A translated group heading must still open the stable, English protocol filter.
for (const ctx of [zh, en]) {
  const panel = fs.readFileSync(path.join(root, 'shell/ui/panel.js'), 'utf8');
  const map = panel.match(/const FILTER_OF = [\s\S]*?;/)[0];
  vm.runInContext(map, ctx);
  assert.equal(vm.runInContext('FILTER_OF[t("Documents")]', ctx), 'documents');
  assert.equal(vm.runInContext('FILTER_OF[t("Images")]', ctx), 'images');
}
for (const file of ['index.html', 'setup.html', 'settings.html', 'window.html']) {
  const html = fs.readFileSync(path.join(root, 'shell/ui', file), 'utf8');
  assert.match(html.match(/<script[^>]+>/)[0], /i18n\.js/);
}
console.log(`Web localization checks passed (${Object.keys(i18n.chinese).length} messages)`);

// Translating labels must not alter file kinds, example filters or render requests.
for (const ctx of [zh, en]) {
  ctx.window = { __TAURI__: { core: {}, path: { homeDir: () => Promise.resolve("/test") } } };
  vm.runInContext(fs.readFileSync(path.join(root, 'shell/ui/results.js'), 'utf8'), ctx);
  const windowSource = fs.readFileSync(path.join(root, 'shell/ui/window.js'), 'utf8');
  vm.runInContext(windowSource.slice(0, windowSource.indexOf('const $ =')), ctx);
  assert.equal(vm.runInContext('JSON.stringify(FILTERS.flatMap(x => x.kinds))', ctx),
    '["screenshot","image","pdf","doc","video","audio"]');
  assert.equal(vm.runInContext('JSON.stringify(EXAMPLES.map(x => x[1]))', ctx),
    '["screenshots","documents","images","audio","video","documents"]');
  assert.equal(vm.runInContext('JSON.stringify(renderOf({kind:"video",loc:3}))', ctx), '["video",3]');
  assert.equal(vm.runInContext('JSON.stringify(renderOf({kind:"image"}))', ctx), '["image",null]');
}
console.log('Search protocol identifiers preserved in both languages');
