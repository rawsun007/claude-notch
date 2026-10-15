# NOTCH POP

A 34-second launch cut of ClaudeNotch in bright pop colours: every scene
pours out of the notch on the downbeat, a card drops out and does what the
app does, and the v0.42 Skills page lands on the drop. Storyboard in
[`brag-plan.md`](brag-plan.md).

    PASSES=6 ./master.sh      # config, track, mix, render, encode: notch-pop.mp4

`film.html` draws every frame as a pure function of time; `rig.mjs` films it
in headless Chrome and streams the frames into ffmpeg (four 120 fps frames
blended into each 30 fps frame for motion blur), so nothing but the finished
segments touches the disk. The MP4 is not committed (see `../README.md`).

Music: "Gimme That Groove!" by Mixkit (#872), under the Mixkit licence;
`master.sh` downloads it.
