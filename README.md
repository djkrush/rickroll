# Rickroll page

A single static page: chat apps see your custom thumbnail/title, the victim sees a decoy
YouTube video that switches to Rick Astley after N seconds.

Everything you must change lives in `src/index.html`. Line numbers below are approximate; search
for the quoted text if they drift.

## Checklist (do these in order)

- [ ] A. Pick the decoy video and thumbnail
- [ ] B. Edit the link preview (`<meta>` tags, top of `index.html`)
- [ ] C. Edit the fake page text (title + view count)
- [ ] D. Edit the `CONFIG` block (videos and timing)
- [ ] E. Test locally over http
- [ ] F. Host it, then set the real thumbnail URL
- [ ] G. Verify the preview and paste the link

---

## A. Pick the decoy video and thumbnail

1. Find a YouTube video that fits the story you're telling in the chat. Copy the 11-character
   id from the URL: `youtube.com/watch?v=` **`XXXXXXXXXXX`**.
2. Confirm it allows embedding. Paste this in a browser, replacing the id; you should see JSON,
   not an error:
   `https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=XXXXXXXXXXX&format=json`
3. Save your thumbnail as `src/thumb.jpg`, 1200x630, under 1 MB. This image is used
   twice: as the chat preview and as the cover before they press play.

## B. Edit the link preview (`<meta>` tags)

These are what the chat app shows. Chat crawlers do not run JavaScript, so they must be edited
by hand. Each value appears more than once; change **every** occurrence.

| What                | Where in `index.html`                                     | Replace with                                |
|---------------------|-----------------------------------------------------------|---------------------------------------------|
| Preview title       | `og:title` **and** `twitter:title`                        | Clickbait headline (same text in both)      |
| Preview description | `name="description"`, `og:description`, `twitter:description` | One-line teaser (same text in all three) |
| Preview image URL   | `og:image` **and** `twitter:image`                        | Full https URL to `thumb.jpg` (see step F)  |
| Site name           | `og:site_name`                                            | "YouTube", "ESPN", etc.                     |

The image URL is the one you cannot fill in until you know your hosting domain. Leave the
`REPLACE-ME.example.com` placeholder until step F so it's easy to grep for.

## C. Edit the fake page text

| What            | Where in `index.html`                          | Notes                                    |
|-----------------|------------------------------------------------|------------------------------------------|
| Browser tab / H1| `<title>...</title>`                           | Shown as the page heading under the player |
| View count line | `<div class="meta">1.2M views · 2 days ago</div>` | Make it plausible for the decoy video |

## D. Edit the `CONFIG` block

Search for `const CONFIG` (around line 62).

| Key                  | Set it to                                                       |
|----------------------|-----------------------------------------------------------------|
| `decoyVideoId`       | The 11-char id from step A                                      |
| `decoyStartSeconds`  | `0`, or a timestamp to skip the decoy's intro                   |
| `switchAfterSeconds` | How long the decoy plays before Rick. 7-20 s works well         |
| `rickVideoId`        | Leave as `dQw4w9WgXcQ`                                          |
| `rickStartSeconds`   | `0` = drum intro, `43` = straight into the chorus               |
| `coverImage`         | Leave as `thumb.jpg`                                            |
| `preloadRick`        | Leave `true`. See "Ads" below                                   |
| `realVideoMinSeconds`| Leave `90` unless the payoff video is shorter than ~90 s        |
| `maxPreloadWaitSeconds`| How long the decoy may overrun while waiting out a slow ad     |

## E. Test locally over http

Never open `index.html` from disk (`file://`). YouTube embeds fail with error 153 without a
referrer. Run a server from the `src` folder instead:

```
cd src
python -m http.server 8000
```

(Python is not installed on this machine — `python` there is the Microsoft Store stub. Either
install Python, or skip local testing and check the deployed Pages URL instead.)

Open http://localhost:8000/ in a private window with extensions off. Press play, confirm the
decoy runs, confirm the switch happens at the right second. Then stop the server
(Ctrl+C in that terminal, or kill the `python` process on port 8000).

## F. Host it, then set the real thumbnail URL

This repo is wired for GitHub Pages. `.github/workflows/pages.yml` publishes the **contents of
`src/`** on every push to `main`, so `index.html` is served at the site root:

    https://djkrush.github.io/rickroll/

One-time setup: GitHub → repo **Settings → Pages → Build and deployment → Source = GitHub
Actions**. After that, deploying is just:

```
git add -A && git commit -m "Update page" && git push
```

Watch the run under the repo's **Actions** tab; the first deploy takes a minute or two.

The thumbnail is therefore at `https://djkrush.github.io/rickroll/thumb.jpg`, already filled into
both `og:image` and `twitter:image`. Open that URL once after the first deploy to confirm it
loads. If you later move to a custom domain, replace **both** occurrences and check nothing is
left behind:

```
grep -n REPLACE-ME src/index.html      # should print nothing
```

## G. Verify the preview and paste the link

1. Paste the page URL into a chat with only yourself (or a test Discord server / Slack DM).
   Confirm the title, description, and thumbnail all render.
2. If the preview is wrong, fix the tags and re-upload. Chat apps cache previews, so paste a
   slightly different URL (`https://yourdomain.com/?v=2`) to force a refetch.
3. Paste into the league chat.

---

## Gotchas

- Chat apps cache link previews. Bump `?v=N` on the URL after any change to the meta tags.
- The decoy video must allow embedding (step A.2). "Video unavailable" means pick another.
- iMessage and some apps show the domain name under the preview. `djkrush.github.io` is visible
  there; a custom domain (Settings → Pages → Custom domain) looks less suspicious.
- Victims must press play once (browsers block autoplay with sound). The cover image makes
  that look normal.

## Ads at the switch

YouTube has no "disable ads" player setting, and the IFrame API deliberately exposes none. What
it does have is a rule you can work around: a pre-roll fires when a video **starts loading**.

So the page loads Rick up front, in a second player that is muted and sitting at opacity 0 behind
the decoy. Any pre-roll plays there, unseen and unheard, usually before the victim has even
pressed play. The page watches the reported duration — during an ad the player reports the *ad's*
length, so anything over `realVideoMinSeconds` means the real video is running — then pauses it at
`rickStartSeconds`. The switch just swaps which player is visible and unmutes. Nothing loads, so
nothing triggers an ad.

If the ad is still going when the decoy hits `switchAfterSeconds`, the decoy keeps playing up to
`maxPreloadWaitSeconds` rather than cutting to an ad, so the switch can land a few seconds late.
Set `preloadRick: false` to go back to the single-player version.

This does not block ads, it just front-runs one. Two things still get through:

- A **mid-roll** in the payoff video. Rare on a 3:32 song; `dQw4w9WgXcQ` doesn't have them.
- The viewer's own client. Premium users see no ads either way.

For a guaranteed-clean switch you'd have to drop YouTube for the payoff and self-host a short
video clip, which is a copyright question rather than a technical one.

## Error 153 "Video player configuration error"

YouTube requires embeds to send a Referer header. Two things cause this:

1. Opening `src/index.html` directly from disk (`file://...`). There is no referrer at all, so the
   embed always fails. Test over http instead (step E).
2. An ad blocker or privacy extension (uBlock, Ghostery, Brave shields) stripping the header.
   Try a private window with extensions off.

The page sets `<meta name="referrer" content="strict-origin-when-cross-origin">` and passes
`origin` to the player, which fixes hosted pages. It cannot fix `file://`.
