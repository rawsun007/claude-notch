/* rig.mjs: films film.html in headless Chrome, one frame at a time.
     node rig.mjs proof 2 9.5 ...   stills into proofs/
     node rig.mjs roll [from] [to]  frames into frames/ at shoot_fps
     node rig.mjs pipe from to seg.mp4  frames streamed into ffmpeg, blended to 30 fps:
                                    nothing touches the disk but the segment
     node rig.mjs duration          prints the film's length */
import fs from "node:fs";
import puppeteer from "puppeteer-core";
import { spawn } from "node:child_process";
const cfg = JSON.parse(fs.readFileSync("config.json", "utf8"));
fs.writeFileSync("film.built.html", fs.readFileSync("film.html", "utf8").replace("CONFIG_JSON", JSON.stringify(cfg)));
const [mode = "roll", ...rest] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: true,
  args: ["--allow-file-access-from-files", "--hide-scrollbars", "--force-color-profile=srgb", "--autoplay-policy=no-user-gesture-required"],
});
const page = await browser.newPage();
await page.setViewport({ width: cfg.width, height: cfg.height, deviceScaleFactor: 1 });
page.on("console", (m) => m.type() === "error" && console.error("CONSOLE", m.text()));
page.on("pageerror", (e) => console.error("STUDIO ERROR", e.message));
await page.goto("file://" + process.cwd() + "/film.built.html", { waitUntil: "domcontentloaded", timeout: 180000 });
await page.evaluate(() => window.studioReady);
const dur = await page.evaluate(() => window.DURATION);
const shoot = async (t, file) => { await page.evaluate((t) => window.paint(t), t); await page.screenshot({ path: file, type: "jpeg", quality: 95 }); };
if (mode === "duration") console.log(dur.toFixed(3));
else if (mode === "proof") {
  fs.mkdirSync("proofs", { recursive: true }); for (const f of fs.readdirSync("proofs")) fs.unlinkSync("proofs/" + f);
  for (const [i, t] of rest.map(Number).entries()) await shoot(t, `proofs/${String(i).padStart(2, "0")}_${t.toFixed(2)}s.jpg`);
} else if (mode === "pipe") {
  // frames go straight into ffmpeg: every sub frames blended into one (a
  // 360-degree shutter at 30 fps: the smoothest smear). Ranges must start on a multiple of sub.
  const from = +rest[0], to = +rest[1], outFile = rest[2];
  const ff = spawn("ffmpeg", ["-v", "error", "-y", "-f", "image2pipe", "-framerate", String(cfg.shoot_fps), "-c:v", "mjpeg", "-i", "-",
    "-vf", `tmix=frames=${cfg.sub}:weights='${Array(cfg.sub).fill(1).join(" ")}',select='eq(mod(n\\,${cfg.sub})\\,${cfg.sub - 1})',setpts=N/30/TB,fps=30`, "-c:v", "libx264", "-preset", "medium", "-crf", "10", "-pix_fmt", "yuv444p", outFile], { stdio: ["pipe", "inherit", "inherit"] });
  for (let f = from; f < to; f++) {
    await page.evaluate((t) => window.paint(t), f / cfg.shoot_fps);
    const buf = await page.screenshot({ type: "jpeg", quality: 95 });
    if (!ff.stdin.write(buf)) await new Promise((ok) => ff.stdin.once("drain", ok));
    if (f % 600 === 0) console.log(`frame ${f}`);
  }
  ff.stdin.end(); await new Promise((ok) => ff.on("close", ok));
} else {
  const total = Math.round(dur * cfg.shoot_fps), from = +(rest[0] ?? 0), to = Math.min(total, +(rest[1] ?? total));
  fs.mkdirSync("frames", { recursive: true });
  for (let f = from; f < to; f++) { await shoot(f / cfg.shoot_fps, `frames/${String(f).padStart(5, "0")}.jpg`); if (f % 600 === 0) console.log(`frame ${f}/${total}`); }
}
const over = await page.evaluate(() => Object.entries(window.SCALES).filter(([, s]) => s > 1.02));
for (const [n, s] of over) console.error(`SOFT: ${n} drawn at ${s.toFixed(2)}x its pixels`);
await Promise.race([browser.close(), new Promise((ok) => setTimeout(ok, 5000))]);
process.exit(0);
