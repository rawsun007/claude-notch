// Every frame is render(t) then a screenshot: a pure function of time.
// Full renders go at renderFps (120) so ffmpeg can blend them into real
// motion blur at 30fps.
import fs from 'node:fs';
import puppeteer from 'puppeteer-core';

const tl = JSON.parse(fs.readFileSync('timeline.json', 'utf8'));
fs.writeFileSync('page.html', fs.readFileSync('index.html', 'utf8').replace('TIMELINE_JSON', JSON.stringify(tl)));
const mode = process.argv[2] || 'full';
const browser = await puppeteer.launch({
  // Any Chromium works; set CHROME to point somewhere else.
  executablePath: process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  args: ['--allow-file-access-from-files', '--hide-scrollbars', '--force-color-profile=srgb', '--font-render-hinting=none'],
});
const page = await browser.newPage();
await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
page.on('pageerror', e => console.error('PAGE ERROR', e.message));
page.on('console', m => { if (m.type() === 'error') console.error('CONSOLE', m.text()); });
await page.goto('file://' + process.cwd() + '/page.html', { waitUntil: 'networkidle0' });
await page.evaluate(() => window.ready);
const shot = async (t, file) => { await page.evaluate(t => render(t), t); await page.screenshot({ path: file, type: 'jpeg', quality: 94 }); };

if (mode === 'stills') {
  fs.mkdirSync('stills', { recursive: true });
  for (const f of fs.readdirSync('stills')) fs.unlinkSync('stills/' + f);
  const ts = process.argv.slice(3).map(Number);
  for (const [i, t] of ts.entries()) await shot(t, `stills/${String(i).padStart(2, '0')}_t${t.toFixed(2)}.jpg`);
} else {
  const n = Math.round(tl.duration * tl.renderFps);
  const from = +(process.argv[3] || 0), to = +(process.argv[4] || n);
  for (let f = from; f < to; f++) {
    await shot(f / tl.renderFps, `frames/${String(f).padStart(5, '0')}.jpg`);
    if (f % 240 === 0) console.log(`frame ${f}/${n}`);
  }
}
await browser.close();
