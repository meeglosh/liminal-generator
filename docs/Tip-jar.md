# Optional native tip jar

Open the gear (**About and support**) to find **Support Liminal Generator**. All features remain free. Tips are repeatable, one-time consumables; they grant no features, credits, subscriptions or permanent entitlements. There is no restore button because these consumables have nothing to restore.

## App Store Connect products

Configured on 2026-09-14 for Liminal Generator (6804471660):

| Product ID | Name | US base price | Apple resource ID |
| --- | --- | --- | --- |
| `com.gapco.LiminalGenerator.tip.small` | Small tip | $1.99 | 6812119841 |
| `com.gapco.LiminalGenerator.tip.coffee` | Buy me a coffee | $4.99 | 6812119763 |
| `com.gapco.LiminalGenerator.tip.tapes` | Keep the tapes rolling | $9.99 | 6812119821 |

All three are `CONSUMABLE`, available in 175 territories plus new territories, with US base pricing and Apple's automatic territory prices. English product localizations, review notes, and a real in-app review screenshot are uploaded. Apple reports **READY_TO_SUBMIT** for all three. This is configuration readiness, not approval for real purchases.

Submit these first in-app purchases with the next App Store app version. The account's Paid Apps agreement, banking and tax information must be active for real sales. No agreements were accepted or banking/tax data modified by this task. Small Business Program enrollment was not changed. Existing TestFlight build 1.0 (8) does not contain the tip jar.

## Implementation

`TipStore` is owned by the app, observes `Transaction.updates` from launch, processes unfinished verified transactions, and finishes each tip. Pending approvals can finish after About closes. Cancellation is quiet; unavailable products, connection failures, restricted payments, pending approval, and unverified transactions are handled explicitly. Thank-you messages only follow verified purchases. No backend or external payment service is used.

`TipJarSection` displays StoreKit's actual localized display name and price. Unavailable products have no tappable fallback price. Purchase buttons disable while loading/purchasing. All main app features work without buying anything.

## Local testing

Use the **Liminal Generator StoreKit** scheme with `Configuration/TipJar.storekit`. That file is included only in the app-hosted StoreKit test target; the normal scheme and production archives use App Store Connect. StoreKit testing does not charge real money.

`TipStoreTests` covers successful repeat tips, cancellation, purchase failure, loading failure/retry, and delayed Ask to Buy completion through transaction updates. On the installed iOS 26.4 and 26.5 runtimes, headless `xcodebuild test` encounters Apple's StoreKit `SKInternalErrorDomain Code=3` / Octane entitlement error. Launching the StoreKit scheme from Xcode initializes the local store for UI inspection. Transaction-test controls require a compatible simulator runtime; both installed runtimes reject these controls even from app-hosted tests. The suite verifies test controls before purchasing and explicitly skips if they are unavailable; the current run skipped all five tests, which is not a purchase-test pass.

## Validation results

- Simulator Debug and device Release builds succeeded; the production app bundle contains no `.storekit` configuration or test bundle.
- Existing generator UI tests (full playback/render/share flow and vertical slider gesture) passed during the Xcode run.
- The tip UI was visually verified with all three localized prices. Xcode's native purchase sheet explicitly identified the no-charge test environment; manual successful purchase, repeat purchase and cancellation were verified.
- App Store Connect confirms all three products are READY_TO_SUBMIT and the bundle identifier has IN_APP_PURCHASE capability enabled.
- Pending approval, injected failures and other automated StoreKit cases remain unverified on these incompatible test runtimes. Run the supplied hosted tests on a compatible runtime and sandbox-test a device/TestFlight build before production release.

## TestFlight

Included in version 1.0 (9), available to the Internal group on 2026-09-14. The signed production archive contains no local StoreKit configuration. Device sandbox purchase verification remains the next check.
