# ClaudeNotch: launch video plan

**What it is:** a macOS menu-bar app that puts Claude Code's permission prompts,
status and spend in the MacBook notch.
**For:** people who leave Claude Code running and go do something else.
**What sets it apart:** you answer the agent from the one place on the screen you
are always looking at, without switching to the terminal.
**Hook:** the site's own line, "The terminal is where you are not looking."
**Visual identity:** the site's cream canvas (#faf9f5), coral (#cc785c), ink
(#141413), Fraunces display serif, Inter, JetBrains Mono. The real app's black
notch cards against that cream.
**Tone:** default (punchy, playful, clean), leaning on the site's editorial calm.
**Format:** 1920x1080, 30fps, 21.5s.

## Storyboard

| # | Time | Scene | On screen | Sound |
|---|---|---|---|---|
| 1 | 0.0-3.4 | Hook | A terminal prompt line waits, dims. "The terminal is where you are not looking." | Pad in, soft ticks |
| 2 | 3.4-6.4 | Reveal | A black notch drops from the top edge. "Claude Code, in your notch." | Whoosh, kick enters |
| 3 | 6.4-10.4 | Highlight 1 | Real footage: `npm install` card, Allow clicked. "Approve a command without leaving your editor." | Pop on card, click on Allow |
| 4 | 10.4-14.2 | Highlight 2 | Real footage: destructive `rm -rf ... sudo` card, Hold to Allow. "rm -rf, sudo and force-push need a press-and-hold." | Rising hold tone |
| 5 | 14.2-17.2 | Highlight 3 | Real footage: "Done, 14 files changed, tests green". "Know the moment it's done." | Chime in key |
| 6 | 17.2-21.5 | Outro | Notch, the pet climbs out of it, app icon, ClaudeNotch, brew command, free for personal use. | Final chord, boop |

All footage is the project's own `demo.mp4`; all copy except scene 5's caption
is lifted from the site. The pet is drawn from the real 16x16 rig in
`PetRig.swift`, in its real coral.
