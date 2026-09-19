# App Store preparation — 1.0.1 (15)

Updated September 18, 2026. Version 1.0.1 build 15 was submitted to App Review at 01:45:26 UTC on September 19, 2026. The submission is **Waiting for Review**. Version 1.0 is live on the App Store; 1.0.1 is an update and will publish **automatically** once Apple approves it.

## Completed

- Version 1.0.1 created for platform IOS with releaseType AFTER_APPROVAL. This is a deliberate change from 1.0, which used manual release: 1.0.1 goes public as soon as review passes.
- Build 15 uploaded with altool (Delivery UUID f41284dc-aba5-478b-91bb-49c35da51458), processed VALID, and selected for version 1.0.1.
- Version 1.0.1 was submitted on its own in submission abd340f6-5f07-4fb5-97b5-c907349fd05b. The three consumable tips were already approved with 1.0 and the API did not require them again; the submission holds exactly one item.
- What's New saved for en-US, covering the BREAKS toggle, the CRT power-on behaviour, the lighter default tape age, and the right-edge smear fix. Read back from the API to confirm the stored text.
- Five native build 15 screenshots at 1320 × 2868 uploaded and processed COMPLETE, in the order 01-main, 02-bass, 03-drums, 04-export, 05-crt-intro. The four build 12 screenshots that App Store Connect copied onto the new version were deleted first, and the set order was pinned explicitly after upload so the listing shows only the new five. Apple's API still calls the 6.9-inch class APP_IPHONE_67.
- Name, subtitle, description, keywords, copyright, content rights, App Review contact and notes, support/privacy URLs, age rating, pricing, and territories all carried over unchanged from 1.0. Nothing in that metadata needed re-entry.
- Data Not Collected privacy disclosure unchanged. See privacy-audit.md.

## Pending

- Monitor App Store Connect for reviewer questions, rejection, or approval.
- No release step is needed. Approval publishes 1.0.1 automatically, replacing 1.0 on the store.

## Links and records

- Support: https://github.com/meeglosh/liminal-generator/tree/codex/app-store-pages
- Privacy: https://github.com/meeglosh/liminal-generator/blob/codex/app-store-pages/PRIVACY.md
- App Store Connect: https://appstoreconnect.apple.com/apps/6804471660/distribution
- Build ID (15): f41284dc-aba5-478b-91bb-49c35da51458
- Version ID (1.0.1): 1a23ca02-a100-4380-a035-40dd4173cd4f
- en-US localization ID: 0593d9ca-23d7-4a2f-91da-b09b56d61adf
- Screenshot set ID (APP_IPHONE_67): a037c0e7-111f-4534-a828-4af6be25bab1
- Review submission ID: abd340f6-5f07-4fb5-97b5-c907349fd05b
- Screenshots: screenshots/; current upload IDs in screenshot-upload.json.
- Previous submission (1.0 build 12): submission 2d528b5c-7f5d-40a4-bc64-fc0141989ebb, build 1c65e8dd-9091-4c66-a1d7-7f4c3fe85cd7 for 1.0 (11) and 47ebb704-27d5-4644-8773-cf9b67b6776d for 1.0 (12), version 88ff7090-568a-4727-b19b-a8d26334725e, screenshot IDs in screenshot-upload-build12.json.

The public documentation lives on remote branch codex/app-store-pages. HTML versions are also prepared under website/, but GitHub Pages is not enabled; the API token lacks Pages administration permission. The configured GitHub document URLs are live and do not depend on Pages.
