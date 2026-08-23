# Loop Licenses

All 10 drum loops bundled in this app were sourced from [Freesound.org](https://freesound.org),
uploaded by user **holizna** (https://freesound.org/people/holizna/), and are licensed
**CC0 1.0 Universal (Public Domain Dedication)**:
https://creativecommons.org/publicdomain/zero/1.0/

Each Freesound sound page confirmed the license badge "Creative Commons 0" pointing to the
above URL (verified individually per file, 2026-08-23). The uploader's standard description on
these sounds states (quoted verbatim from the sound pages):

> "Left Over Drum Loops from my official sample packs on my website (which are also completely
> free). CC0, you do not need to credit me, but credit is appreciated — mostly because I love to
> see what people use my work for!"

This states the loops are original material pulled from the uploader's own commercial sample
packs (not samples of copyrighted third-party recordings), consistent with holizna's broader
Freesound catalog (98+ uploads, all CC0, all self-produced sample-pack leftovers). No file below
contains melodic/pitched instrumentation, samples of records, or vocals — kick/snare/hat/vinyl-
texture drum elements only.

Download date for all files: **2026-08-23**.

Freesound does not allow anonymous/unauthenticated download of the original uploaded WAV file
(requires a logged-in account); the original-quality "HQ" preview MP3 (a 128–320kbps re-encode
of the original, generated and served by Freesound itself, not a re-upload by a third party) is
served without authentication from Freesound's own CDN and was used as the source audio. This is
still the CC0-licensed uploader's own content, just via Freesound's public preview encode rather
than the raw studio WAV.

## Processing applied to every file

1. Downloaded Freesound "HQ" preview MP3 from `https://cdn.freesound.org/previews/...-hq.mp3`.
2. Decoded to WAV, 44100 Hz, mono, 16-bit PCM (`ffmpeg -ar 44100 -ac 1 -sample_fmt s16`).
3. Verified the source's stated BPM arithmetically: source duration ÷ (240/BPM) landed on a
   whole number of bars within a fraction of a millisecond for every file (max observed error
   0.023 ms), confirming the stated tempo is accurate.
4. Trimmed to exactly 4 bars at the stated BPM (sample-accurate cut via Python `wave`, not
   `ffmpeg -t`, to avoid container timestamp rounding) — target = 960/BPM seconds.
5. Applied a 2.5 ms linear fade-in and fade-out at the two loop edges (declick pass) because the
   raw bar-boundary cut produced an audible sample-value discontinuity (jump) at the wrap point
   for several of the files (up to 14% of full scale on `loop_95_dusty`). After the 2.5 ms
   fades the sample value at both the first and last sample of every file is exactly 0, so the
   loop point is click-free when tiled back-to-back. Fade length is well under the 3 ms ceiling
   and is not audible as a fade.
6. Peak-normalized to -3.0 dBFS: measured pre-normalization peak via
   `ffmpeg -af volumedetect`, then applied `ffmpeg -af volume=<computed>dB` to bring true peak to
   -3.0 dBFS exactly (re-verified with a second `volumedetect` pass after normalization).
7. Renamed to `loop_<bpm>_<slug>.wav`.

## File-by-file record

### loop_70_drift.wav
- Source: https://freesound.org/people/holizna/sounds/629140/ ("Lofi Drum Loop 70 BPM.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `Lofi Drum Loop 70 BPM.wav` (downloaded as HQ preview `629140_12574855-hq.mp3`)
- BPM: 70, 4 bars, trimmed from the source's native 4-bar length (13.714 s)

### loop_76_midnight.wav
- Source: https://freesound.org/people/holizna/sounds/629134/ ("76 BPM LOFI DRUM LOOP.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `76 BPM LOFI DRUM LOOP.wav` (downloaded as HQ preview `629134_12574855-hq.mp3`)
- BPM: 76, 4 bars, trimmed from the source's native 4-bar length (12.632 s)

### loop_76_amber.wav
- Source: https://freesound.org/people/holizna/sounds/629135/ ("76 BPM LOFI DRUM(2) LOOP.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `76 BPM LOFI DRUM(2) LOOP.wav` (downloaded as HQ preview `629135_12574855-hq.mp3`)
- BPM: 76, 4 bars, trimmed from source's 8-bar loop (25.263 s) — first 4 bars taken

### loop_80_shadow.wav
- Source: https://freesound.org/people/holizna/sounds/852272/ ("Trap Drum Loop #14 80 BPM")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `Trap Drum Loop #14 80 BPM` (downloaded as HQ preview `852272_12574855-hq.mp3`)
- BPM: 80, 4 bars, trimmed from the source's native 4-bar length (12.000 s)

### loop_85_hazy.wav
- Source: https://freesound.org/people/holizna/sounds/621177/ ("85 BPM Lofi HipHop Drum Loop.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `85 BPM Lofi HipHop Drum Loop.wav` (downloaded as HQ preview `621177_12574855-hq.mp3`)
- BPM: 85, 4 bars, trimmed from source's 12-bar loop (33.882 s) — first 4 bars taken

### loop_88_funky.wav
- Source: https://freesound.org/people/holizna/sounds/629137/ ("Funky Lofi Drum Loop 88 BPM.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `Funky Lofi Drum Loop 88 BPM.wav` (downloaded as HQ preview `629137_12574855-hq.mp3`)
- BPM: 88, 4 bars, trimmed from source's 8-bar loop (21.818 s) — first 4 bars taken

### loop_90_grit.wav
- Source: https://freesound.org/people/holizna/sounds/629139/ ("BoomBap Drums 90 BPM.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `BoomBap Drums 90 BPM.wav` (downloaded as HQ preview `629139_12574855-hq.mp3`)
- BPM: 90, 4 bars, trimmed from source's 8-bar loop (21.333 s) — first 4 bars taken

### loop_95_boombap.wav
- Source: https://freesound.org/people/holizna/sounds/629132/ ("Boom Bap Hiphop Kick Snare Loop 95 BPM.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `Boom Bap Hiphop Kick Snare Loop 95 BPM.wav` (downloaded as HQ preview `629132_12574855-hq.mp3`)
- BPM: 95, 4 bars, trimmed from source's 16-bar loop (40.421 s) — first 4 bars taken

### loop_95_dusty.wav
- Source: https://freesound.org/people/holizna/sounds/629138/ ("Dusty Lofi Drum Loop 95 BPM.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `Dusty Lofi Drum Loop 95 BPM.wav` (downloaded as HQ preview `629138_12574855-hq.mp3`)
- BPM: 95, 4 bars, trimmed from source's 8-bar loop (20.211 s) — first 4 bars taken
- Note: had the largest raw seam discontinuity pre-declick (~14% FS); 2.5 ms edge fades applied,
  post-fix seam jump is 0.

### loop_95_vinyl.wav
- Source: https://freesound.org/people/holizna/sounds/629141/ ("Lofi - Kick+Snare+Vinyl Static 95 BPM.wav")
- Author/uploader: holizna
- License: CC0 1.0 (https://creativecommons.org/publicdomain/zero/1.0/)
- Original filename: `Lofi - Kick+Snare+Vinyl Static 95 BPM.wav` (downloaded as HQ preview `629141_12574855-hq.mp3`)
- BPM: 95, 4 bars, trimmed from the source's native 4-bar length (10.105 s)
- Note: the "vinyl static" is the uploader's own drum-kit texture layer, per the sound
  description — not a sample of a copyrighted vinyl record.

## Rejected candidates (not used)

- `Tattoo_Beatz` — "Boom Bap Eminem Beats.wav" (Freesound): named after a copyrighted artist;
  rejected outright without further checking regardless of the license tag on the listing —
  too high risk of uncleared reference/sample content.
- Various non-holizna Freesound results returned by license-filtered search (e.g. `jnealy`,
  `dpren`, `Jav1v1`, `ethanchase7744`, `deleted_user_5042749`) were not used: not needed once 10
  verifiable CC0 originals from a single well-documented uploader were found, and per-file
  verification effort was prioritized on those.
- Archive.org search for "(lofi OR lo-fi OR boombap) drum loop pack" and "(lofi OR lo-fi) AND
  drum AND loop" returned almost no explicitly CC0/public-domain items relevant to drum-only
  loops in the 68–96 BPM range (results were mostly full tracks/albums under by/by-nc/by-nd
  licenses, unrelated CIA document scans, etc.) — not pursued further.
- GitHub CC0 sample-pack repos surfaced by search (e.g. `SoundSafari/CC0-1.0-Music`,
  `madjin/awesome-cc0`, `lavenderdotpet/CC0-Public-Domain-Sounds`) were not pursued once the
  Freesound holizna catalog supplied enough verifiable, drums-only, correctly-tempo'd material;
  their contents are broader collections that would each need per-file license/BPM/content
  verification.
