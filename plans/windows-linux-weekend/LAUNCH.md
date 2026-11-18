# Monday launch

## The timing problem, and the fix

winget manifests are reviewed: automated validation plus, often, a human, and
a new package typically takes one to a few days to merge. If we tag on Monday
and submit then, `winget install` will not work on launch day.

**So: publish the real `windows-v0.45.0` release quietly on Sunday night and
submit the winget manifest straight away. Announce on Monday.** If winget
has not merged by the announcement, the website shows the download first and
says winget is "on its way", then flips once it merges.

## Sunday night (after R2 passes)

1. Tag `windows-v0.45.0` (and `linux-v0.45.0` if the shared core changed,
   which it will have). Not marked latest: the Mac DMG stays the latest
   release, because the Mac updater and the Homebrew cask read it.
2. CI builds and attaches `ClaudeNotch-0.45.0-windows-x64-setup.exe`.
3. Download that exact file on the Windows machine, install, smoke test
   (card, danger card, uninstall).
4. `wingetcreate new <release asset URL>`: identifier `Rawsun.ClaudeNotch`,
   installer type `inno`, scope `user`, publisher, license
   `PolyForm-Noncommercial-1.0.0`, short description, release notes URL
   (the Windows changelog page). Submit. Note the PR number.
5. Write the GitHub release notes (no em dashes): what it is, install,
   requirements (Windows 10 22H2 or 11, x64 or Arm via emulation, Claude Code
   native install), known limits (v1 has no Windows Hello, no auto-approve,
   no cost meter yet).

## Monday morning: website (Mac)

In `../claude mac app website`:

1. `app/changelog/releases.ts`: add `"windows"` to `Platform`, a
   `PLATFORM_LABEL` entry, and the 0.45.0 Windows entry with its download.
   Add the Linux 0.45.0 entry too.
2. `app/changelog/windows/page.tsx`: replace "Coming soon" with the release
   list and an install box: **winget first**
   (`winget install Rawsun.ClaudeNotch`), download second. Remove
   `robots: { index: false }`.
3. `PlatformTabs.tsx`: Windows tab shows its version instead of "Coming soon".
4. `app/sitemap.ts`: add `/changelog/windows/`.
5. Homepage: the "New" pill becomes "ClaudeNotch now runs on Windows and
   Linux" (same LinuxNotice component, renamed), linking to the Windows page.
   Keep the "still in development, use with caution, tell us about bugs"
   line; it applies to Windows even more.
6. Download / install section of the homepage: a Windows option.
7. Build, check with headless Chrome at desktop and 500 px, publish to
   `docs/`, commit, push (the usual flow in CLAUDE.md).

Root `README.md` of the app repo: a Windows section pointing at
`windows/README.md`.

## Monday: announce

Only after the website is live and the download link is checked from a
browser that is not ours.

- X / LinkedIn: one short post, one screenshot of the card on Windows over a
  terminal, the link to the Windows page. Say it is new and we want bug
  reports.
- GitHub: pin an issue "Windows feedback" for reports.
- If winget is still in review: say "winget coming in a day or two, download
  from the page meanwhile".

## Monday evening

- Watch issues; fix what blocks people the same day (`windows-v0.45.1`).
- Once winget merges: website install box puts winget first, check
  `winget install Rawsun.ClaudeNotch` on the Windows machine (or a VM).
- Once the signing certificate is verified: sign from the next release on.

## Do not

- Write SmartScreen bypass steps anywhere ("More info", "Run anyway").
- Mark the Windows or Linux release as GitHub "latest".
- Touch the Mac DMG, cask or Mac release flow for this launch.
