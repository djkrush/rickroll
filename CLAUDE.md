# CLAUDE.md

## What this is

A single static prank page. Chat apps render a custom link preview from the `<meta>` tags; the
visitor sees a decoy YouTube video that swaps to Rick Astley after N seconds.

No build system, no dependencies, no tests, no package manager. The whole app is
`src/index.html` (188 lines: meta tags, inline CSS, inline JS) plus `src/thumb.jpg`.

## Layout

```
wizard.ps1                     interactive setup + test + ship; the normal way to change the page
README.md                      step-by-step setup guide for the human (A-G checklist + gotchas)
src/index.html                 the entire app
src/thumb.jpg                  482x860 portrait image, used twice: chat preview (og:image) and pre-play cover
src/.nojekyll                  stops Pages running the files through Jekyll
.github/workflows/pages.yml    publishes src/ to GitHub Pages on push to main
```

Only the *contents* of `src/` ship, so `index.html` is at the site root and `thumb.jpg` sits next
to it. Nothing outside `src/` reaches the site.

## Editing

Three blocks in `index.html`, in source order:

1. **Link preview** — `<title>`, `description`, `og:*`, `twitter:*`. Chat crawlers don't run JS,
   so these are hand-edited and several values are duplicated across tags (title in `og:title` +
   `twitter:title`, description in three places, image URL in two). Change **every** occurrence.
2. **Page text** — `<title>` doubles as the on-page `<h1>` (set at runtime from `document.title`);
   the `.meta` div holds the fake view count.
3. **`CONFIG`** — the only knobs for the prank itself: `decoyVideoId`, `decoyStartSeconds`,
   `switchAfterSeconds`, `rickVideoId`, `rickStartSeconds`, `coverImage`, plus the ad-preload
   settings `preloadRick`, `realVideoMinSeconds` and `maxPreloadWaitSeconds`.

`og:image` and `twitter:image` hold the absolute URL
`https://djkrush.github.io/rickroll/thumb.jpg` — link previews can't resolve relative paths, so
both must change together if the domain ever does.

## The wizard

`.\wizard.ps1` is the normal path for setting up a prank. It prompts for the handful of values
that actually vary, writes them into **every** duplicated tag at once, verifies the thumbnail,
serves the page locally, and only then — on an explicit yes — commits on a branch, merges to
`main`, pushes and prints the live URL with a fresh `?v=` cache-buster.

Editing `index.html` by hand is still fine, but the wizard exists because the duplicated meta
tags are the easiest thing in this project to get half-right.

```
.\wizard.ps1              # the full run
.\wizard.ps1 -SelfTest    # non-interactive; checks every rewrite anchor still matches
.\wizard.ps1 -Port 8123   # different local port
.\wizard.ps1 -NoServe     # skip the local test (not recommended)
```

**Run `-SelfTest` after any edit to `index.html`'s structure.** The wizard finds its targets by
regex, so renaming a tag or a `CONFIG` key silently breaks it; the self-test catches that in a
second and writes nothing. It also guards that the rewrite preserves `id="rick"`, `id="yt"`, the
`#cover` z-index and `preloadRick`.

The rewrite lives in one function, `Set-PrankValues`. Add new fields there, and add a matching
assertion to the `-SelfTest` block.

The wizard serves with `python -m http.server`, falling back to a small TCP static server built
into the script if Python ever goes missing. `Test-RealPython` runs the interpreter rather than
trusting `Get-Command`, since the Store stub answers to the name without being Python. It
refuses to commit if the diff contains anything credential-shaped — this project needs no secrets,
so a match means something is wrong.

## How to make a change

**Never commit straight to `main`.** `main` is the deploy branch: any push to it publishes within
a couple of minutes to a URL that may already be sitting in a group chat. There is no staging
environment and no way to take a link back once it has been posted.

Work on a branch, or in a worktree if you want the deployed copy left intact alongside:

```
git worktree add ../rickroll-work -b fix-something
cd ../rickroll-work
# ...edit, test...
git worktree remove ../rickroll-work      # when done
```

A branch push does **not** deploy — `pages.yml` only triggers on `main` — so branches are safe to
push for review. Merging to `main` is the deploy.

Then test before merging:

1. Serve `src/` over http and open it in a browser (see **Running it** — note the Python caveat).
2. **Actually look at the rendered page.** Grepping the HTML is not testing. A `z-index`
   regression once left the real YouTube poster, title bar and "Watch on YouTube" button showing
   in place of the fake cover, and every static check passed while it was broken.
3. Press play and watch the full switch, including what the frame looks like at the moment it
   swaps.
4. Check the browser console for errors — YouTube embed failures surface there.

One thing local testing cannot cover: **link previews**. Chat crawlers need a public URL, so
`og:*` changes are only verifiable after they are on `main` and deployed. Verify those by pasting
into a chat with only yourself, with a fresh `?v=N` each time.

## Deploying

Live at https://djkrush.github.io/rickroll/ from the `djkrush/rickroll` repo. Pushing to `main`
runs `.github/workflows/pages.yml`, which uploads `src/` as the Pages artifact and deploys it —
there is no `gh-pages` branch and nothing to build.

The repo's Pages source must be **GitHub Actions** (Settings → Pages), not "Deploy from a
branch": a branch deploy serves the repo root and would 404, since `index.html` is under `src/`.

`gh` is not installed on this machine, so repo settings changes happen in the GitHub web UI.

## Running it

Always over http, never `file://`:

```
cd src && python -m http.server 8000
```

Then open http://localhost:8000/ in a private window with extensions off.

Python 3.14.7 is installed per-user at `%LOCALAPPDATA%\Programs\Python\Python314` (winget,
`Python.Python.3.14`), ahead of the `WindowsApps` stubs on PATH. `python3.exe` there is a copy of
`python.exe` — the python.org installer doesn't create one, so without it `python3` falls through
to the Store stub.

## Gotchas

- **Error 153 / "Video player configuration error"** means the YouTube embed got no `Referer`.
  Causes: opening the file from disk (`file://` — unfixable, use a server), or an ad blocker /
  privacy extension stripping the header. The page already sets
  `<meta name="referrer" content="strict-origin-when-cross-origin">` and passes `origin` to the
  player, which covers hosted pages.
- **The decoy video must allow embedding.** Check before using an id:
  `https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=<ID>&format=json` — JSON
  means yes, an error means pick another video.
- **Chat apps cache link previews.** After changing meta tags, re-test with a fresh query string
  (`?v=2`) or the old preview comes back.
- **Autoplay with sound is blocked**, hence the cover image and play button: the click is the
  user gesture that lets `player.playVideo()` run.
- The switch is driven by polling `player.getCurrentTime()` every 250 ms and comparing against
  `decoyStartSeconds`, not by a wall-clock timer — seeking or pausing the decoy shifts when it
  fires.
- **Two players, not one.** `#yt` holds the decoy; `#rick` sits behind it at opacity 0, muted,
  playing from page load so any pre-roll ad burns off unseen. The switch swaps visibility and
  unmutes — it must never call `loadVideoById`, because *loading* is what triggers a pre-roll.
  That was the whole point of the change; keep it in mind before "simplifying" back to one player.
  The single-player path still exists as the fallback when preloading fails or is turned off.
- The hidden player uses **opacity, not `display:none`** — a display-hidden player can stop
  playing in some browsers, which would defeat the ad burn.
- "Is the ad over?" is inferred from `getDuration() > realVideoMinSeconds`, since during a
  pre-roll the player reports the ad's duration. If the payoff video is ever changed to something
  shorter than ~90 s, that threshold has to come down with it.
- **The three layers are `#rick` (0), `#yt` (1), `#cover` (3)** and all three need an explicit
  `z-index`. `#cover` at `z-index: auto` loses to `#yt` no matter where it sits in the DOM, which
  silently exposes the real YouTube player. Verify with
  `document.elementFromPoint(x, y)` — it must return `DIV#cover` before play.
