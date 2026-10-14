# App Store Optimization plan — Liminal Generator

Drafted 2026-10-11. Status 2026-10-12: sections 1 (keywords), 3 (promotional text) and the captioned screenshots from
section 5 are applied in App Store Connect (promo text on live 1.0.1; keywords and screenshots on draft 1.0.2). The rest is
not done. 1.0.2 still needs a build before it can be submitted.

No search-volume or ranking data was available when this was written (no ASO tool or ASC analytics access).
Keyword choices are reasoned from how Apple indexes metadata and from the app's content, not measured.
Validate them against App Store Connect > Analytics > Search (impressions by source) after a couple of weeks.

## How Apple indexes metadata (the rules the plan follows)
- Indexed fields: app name, subtitle, keyword field (100 chars). The description is NOT indexed on iOS.
- Words already in the name or subtitle never need repeating in the keyword field.
- Use commas with no spaces; singular forms cover plurals; do not repeat words.
- Apple combines words across fields into phrases, so "ambient" in the subtitle plus "lofi" in the keywords
  can match "ambient lofi".

## 1. Keyword field (biggest, free win)
Current (95 chars): `ambient,lofi,synth,generative,music,liminal,vhs,dreamcore,soundscape,video,tape,beats,nostalgia`

Problems: `ambient`, `music`, `vhs` are already in the subtitle ("Ambient Music & VHS Visuals") and `liminal`
is in the name, so four of thirteen terms are wasted slots.

Proposed (92 chars of 100, in `keywords-proposed.txt`):
`lofi,chill,relaxing,study,sleep,dreamcore,vaporwave,retro,analog,synth,generative,soundscape`

Rationale: adds the intent terms people actually search for with this kind of app (chill, relaxing, study,
sleep), adjacent aesthetic communities (vaporwave, retro, analog). `weirdcore` and `camcorder` did not fit in 100 chars; candidates to swap in. Dropped `video`, `tape`
and `beats` as low-intent or generic; `nostalgia` is dropped because the in-app slider name is not a search term
people use. Swap in `meditation` or `focus` if analytics show demand.

## 2. Subtitle (30 chars max)
Current: `Ambient Music & VHS Visuals` (27). It is good: two high-value words, and it says what the app is.
Optional test for the next version: `Ambient Lofi & VHS Video Maker` (30) adds "lofi" and "video maker" at the
cost of "music". Only switch if the Search analytics suggest lofi/video queries are the entry point. "Music" is
a very broad head term, so keep it unless data says otherwise.

## 3. Promotional text (170 chars, editable ANYTIME without review)
Use this for free now, even while 1.0.1 is in review. Suggested:
`Generate endless ambient music over VHS-filtered empty spaces, then render a shareable two-minute video. Free, no account, no ads.`
Change it seasonally (it is not indexed, but it affects conversion).

## 4. Description (conversion, not search ranking)
Current copy is strong. Small changes for the next version:
- Move "FREE TO EXPLORE" claims into the first lines: "Free. No account. No ads." converts well above the fold.
- Lead with the outcome ("make a shareable VHS music video in a minute"), since the first three lines show
  before "more".
- Keep the "Support:" line; add the privacy link if allowed.

## 5. Screenshots (largest conversion lever after the icon)
- The first three screenshots decide most browsers' tap. Add short caption text above the device frame
  ("Generate ambient music", "Add bass and lo-fi beats", "Render a VHS video") rather than bare UI.
- Keep the playing-state hero first. `05-crt-intro.png` is fifth; consider testing it earlier.
- Consider an App Preview video (15-30s) using the CRT power-on and typewriter intro; autoplay video in search
  results lifts installs. A screen recording of an actual render is enough.

## 6. Ratings and reviews
Rating count and average affect rank and conversion more than any keyword. The app has no review prompt.
Suggested change (code, next build): call `SKStoreReviewController` / `requestReview` once, after a user's
first completed render and share (a success moment), never on launch. Apple limits it to 3 prompts per year.

## 7. Product page extras (no review for most)
- **Custom Product Pages**: make variants for "lofi", "dreamcore" and "study music" audiences; link each from
  its own social posts. Each can carry different screenshots.
- **In-App Events** (needs review): e.g. a themed release, which appears in search and on the product page.
- **Localization**: a cheap multiplier. Apple indexes the US store for the en-US keywords plus the es-MX
  localization, so adding Spanish (Mexico) gives a second 100-character keyword field for US searches.
  Other localizations (e.g. en-GB, en-AU) add keyword fields for those storefronts. Each needs a keyword field
  and subtitle; the rest can reuse the English text.

## 8. Off-store traffic (what actually drives volume for a new free app)
- Short vertical clips of rendered videos are the product. Posting renders to TikTok, Reels and YouTube
  Shorts with the app name and a link is the most direct acquisition channel; the dreamcore/liminal community is
  active on all three.
- The app's own share flow already carries a watermark; keep it visible, it is free attribution.
- Post in r/liminalspace, r/dreamcore and r/vaporwave following each subreddit's self-promotion rules.
- Make the existing GitHub Pages support page a minimal landing page with the App Store badge and a sample clip.

## Suggested order
1. Now, no review needed: set promotional text (section 3).
2. Next version (1.0.2 or 1.1): keyword field, optional subtitle test, description tweaks, captioned
   screenshots, review prompt, add Spanish/UK localizations.
3. In parallel: record an App Preview video and start posting rendered clips.
4. After 2 to 4 weeks: read Search analytics and iterate on keywords.

## Applied 2026-10-14
- en-US description on draft 1.0.2 now opens with "Free. No account. No ads." (see `description.txt`).
- es-MX added to draft 1.0.2: description, keywords (`relajante,estudiar,dormir,calma,concentracion,retro,vintage,nostalgia,sintetizador,lofi,atmosferico`, 99 chars), promotional text, and subtitle "Música ambiental y video VHS" (app-info localization d39527ec-aa6f-41d3-9b0c-5d45e3602f19). Version localization 690f1628-ef51-433f-86f2-2311bb836dad. Spanish copy is machine-written and has not been reviewed by a native speaker.
- What's New written and applied to both locales 2026-10-14 (info-button change and one-time rating prompt).
- Still missing on 1.0.2: a build, and updated screenshots (current ones show the old gear icon).
