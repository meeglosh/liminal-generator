# App privacy audit — build 11

Audited September 15, 2026. App Store Connect disclosure **Data Not Collected** was saved and published through the website.

## Evidence

- App has no developer backend, accounts, advertising, analytics SDKs, tracking identifiers, or custom network requests.
- Music synthesis, bundled-image processing, and video rendering run on device. Video files are temporary and leave the app only through the user-selected system share destination.
- StoreKit 2 products and verified transactions are handled on device in `TipStore.swift`. No purchase data is transmitted to a developer server. Apple operates payment processing.
- About links open the external GitHub support/privacy pages. Voluntary support email is described separately in the privacy policy.
- Release source contains no UserDefaults/AppStorage, file timestamp, disk-space, boot-time, or active-keyboard required-reason API use found in the audit. The debug harness reads file attributes only inside `#if DEBUG` and is absent from Release behavior.
- No third-party binary SDKs are included. No camera, microphone, location, contacts, or tracking permission is requested.
- Export compliance is set to no non-exempt encryption.

The declaration follows Apple's definition of collection: data leaving the device and being accessible to the developer or third-party partners beyond servicing the request. Apple's own services and purely on-device processing are treated according to Apple's guidance. Revisit this declaration before introducing analytics, account storage, uploaded media, or a transaction backend.

Sources:

- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api

Public policy: https://github.com/meeglosh/liminal-generator/blob/codex/app-store-pages/PRIVACY.md
