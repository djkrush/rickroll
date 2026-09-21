# CLAUDE.md

## What this is

A single static prank page. Chat apps render a custom link preview from the `<meta>` tags; the
visitor sees a decoy YouTube video that swaps to Rick Astley after N seconds.

No build system, no dependencies, no tests, no package manager. The whole app is
`src/index.html` (114 lines: meta tags, inline CSS, inline JS) plus `src/thumb.jpg`.

## Layout

```
README.md                      step-by-step setup guide for the human (A-G checklist + gotchas)
src/index.html                 the entire app
src/thumb.jpg                  1200x630 image, used twice: chat preview (og:image) and pre-play cover
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
   `switchAfterSeconds`, `rickVideoId`, `rickStartSeconds`, `coverImage`.

`og:image` and `twitter:image` hold the absolute URL
`https://djkrush.github.io/rickroll/thumb.jpg` — link previews can't resolve relative paths, so
both must change together if the domain ever does.

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

Then open http://localhost:8000/ in a private window with extensions off. Note that Python is
**not** installed here (`python` resolves to the Microsoft Store stub), so local testing needs a
Python install or another static server; otherwise test against the deployed Pages URL.

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
