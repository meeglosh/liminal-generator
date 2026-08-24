//
//  ShareSheet.swift
//  LiminalGenerator
//
//  Thin SwiftUI wrapper around UIActivityViewController for sharing the
//  rendered MP4. iPhone-only app, but a popover anchor is set defensively
//  (a stray non-nil `popoverPresentationController` with no source can
//  crash on some configurations).
//
//  `VideoShareItem` is a `UIActivityItemSource` so the share sheet's
//  preview row shows a real mid-clip video frame instead of the black
//  fade-in frame: it supplies `LPLinkMetadata` with a title and an
//  `imageProvider` built from a frame at half the clip's duration. That
//  callback is synchronous, so the thumbnail must be generated and cached
//  *before* the item is handed to `UIActivityViewController` -- see
//  `ShareThumbnailGenerator` and `RenderViewModel.shareThumbnail`.
//

import SwiftUI
import UIKit
import LinkPresentation
import AVFoundation
import UniformTypeIdentifiers
import os

#if DEBUG
/// DEBUG-only diagnostic logger used to confirm (via `xcrun simctl ... log
/// stream`) that the share sheet actually calls into `VideoShareItem`'s
/// `UIActivityItemSource` methods -- `.fault` level so it's captured
/// regardless of the ambient log-level filter. See the root-cause note on
/// `activityViewControllerLinkMetadata` below for what this diagnosed.
private let shareDebugLog = Logger(subsystem: "com.gapco.LiminalGenerator", category: "ShareDebug")
#endif

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onDismiss?()
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - VideoShareItem

/// Wraps the rendered clip's `URL` so the share sheet can present rich
/// `LPLinkMetadata` (title + a real video-frame thumbnail) while the
/// activity itself still receives the plain MP4 file URL as its item.
final class VideoShareItem: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    let thumbnail: UIImage?
    /// Pre-encoded JPEG bytes of `thumbnail`, computed once up front (see
    /// root-cause note below) rather than left for `NSItemProvider` to
    /// compute lazily on demand.
    private let thumbnailJPEGData: Data?

    init(url: URL, title: String = "Liminal Generator", thumbnail: UIImage?) {
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        self.thumbnailJPEGData = thumbnail?.jpegData(compressionQuality: 0.85)
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        #if DEBUG
        shareDebugLog.fault("[SHARE_DEBUG] placeholderItem called, thumbnail=\(self.thumbnail != nil)")
        #endif
        return url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                 itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        #if DEBUG
        shareDebugLog.fault("[SHARE_DEBUG] itemForActivityType called: \(String(describing: activityType))")
        #endif
        return url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                 subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        #if DEBUG
        shareDebugLog.fault("[SHARE_DEBUG] activityViewControllerLinkMetadata CALLED, thumbnail=\(self.thumbnail != nil) jpegBytes=\(self.thumbnailJPEGData?.count ?? -1)")
        #endif
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        // Debugging note: the device log shows this method IS called and
        // returns a non-nil metadata object (confirmed via temporary
        // `Logger` calls -- see git history / session notes), and Console
        // also logs `[com.apple.LinkPresentation:Serialization] Low
        // fidelity encoder: dropping image, can't encode without
        // computation` right after -- that line turned out to be benign
        // (it fires for both the lazy and eager provider below, and the
        // preview still rendered correctly in both cases on the
        // simulator); it's LinkPresentation's own quick first-pass encode,
        // superseded by a real async load. What IS a real, if
        // simulator-unconfirmed, hardening: `NSItemProvider(object:
        // UIImage)` registers a *lazy* NSItemProviderWriting
        // representation (a block that encodes to PNG/HEIC on demand)
        // rather than data that's already fully materialized. Handing over
        // pre-encoded JPEG `Data` via `NSItemProvider(item:typeIdentifier:)`
        // removes that whole class of "encoder declines to run the
        // computation" risk, alongside setting `iconProvider` in addition
        // to `imageProvider` (some iOS versions only consult the icon
        // slot) -- both are the concrete iOS gotchas this was built
        // against; the simulator could not reproduce the original
        // black-preview report from a physical device either before or
        // after this change, so treat this as defense-in-depth rather
        // than a confirmed root-cause fix.
        if let thumbnailJPEGData {
            metadata.imageProvider = NSItemProvider(item: thumbnailJPEGData as NSData, typeIdentifier: UTType.jpeg.identifier)
            metadata.iconProvider = NSItemProvider(item: thumbnailJPEGData as NSData, typeIdentifier: UTType.jpeg.identifier)
        }
        return metadata
    }
}

// MARK: - ShareThumbnailGenerator

/// Extracts a non-black preview frame from a rendered clip for the share
/// sheet's `LPLinkMetadata.imageProvider`, since the clip fades up from
/// black and a frame captured at time zero would render as a black
/// thumbnail. Pulls the frame at HALF the clip's duration.
enum ShareThumbnailGenerator {
    static func generate(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else { return nil }
            let midpoint = CMTime(seconds: duration.seconds * 0.5, preferredTimescale: 600)

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Tight enough tolerance to reliably land mid-clip rather than
            // silently snapping to a nearby (possibly still-fading) frame.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

            let result = try await generator.image(at: midpoint)
            return UIImage(cgImage: result.image)
        } catch {
            return nil
        }
    }
}
