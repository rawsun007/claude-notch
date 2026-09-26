// Frame capture. Every frame is render(t) on a fresh time, then a screenshot,
// so the video is a pure function of time and nothing depends on wall clock.
import fs from 'node:fs';
import puppeteer from 'puppeteer-core';

const tl = JSON.parse(fs.readFileSync('timeline.json', 'utf8'));
fs.writeFileSync('page.html', fs.readFileSync('index.html', 'utf8').replace('TIMELINE_JSON', JSON.stringify(tl)));

const mode = process.argv[2] || 'full';
const browser = await puppeteer.launch({
  // Any Chromium works; set CHROME to point somewhere else.
  executablePath: process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: true,
  args: ['--allow-file-access-from-files', '--hide-scrollbars', '--force-color-profile=srgb'],
});
const page = await browser.newPage();
await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
page.on('pageerror', e => console.error('PAGE ERROR', e.message));
await page.goto('file://' + process.cwd() + '/page.html', { waitUntil: 'networkidle0' });
await page.evaluate(() => window.ready);

const shot = async (t, file) => {
  await page.evaluate(t => render(t), t);
  await page.screenshot({ path: file, type: 'jpeg', quality: 95 });
};

if (mode === 'stills') {
  fs.mkdirSync('stills', { recursive: true });
  for (const t of process.argv.slice(3).map(Number)) await shot(t, `stills/t${t.toFixed(2)}.jpg`);
} else {
  const n = Math.round(tl.duration * tl.fps);
  for (let f = 0; f < n; f++) {
    await shot(f / tl.fps, `frames/${String(f).padStart(5, '0')}.jpg`);
    if (f % 60 === 0) console.log(`frame ${f}/${n}`);
  }
}
await browser.close();
