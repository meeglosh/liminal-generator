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

    init(url: URL, title: String = "Liminal Generator", thumbnail: UIImage?) {
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                 itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                 subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        if let thumbnail {
            metadata.imageProvider = NSItemProvider(object: thumbnail)
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
