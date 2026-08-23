//
//  ShareSheet.swift
//  LiminalGenerator
//
//  Thin SwiftUI wrapper around UIActivityViewController for sharing the
//  rendered MP4. iPhone-only app, but a popover anchor is set defensively
//  (a stray non-nil `popoverPresentationController` with no source can
//  crash on some configurations).
//

import SwiftUI
import UIKit

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
