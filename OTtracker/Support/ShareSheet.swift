import SwiftUI
import UIKit
import MessageUI

/// UIActivityViewController wrapper for files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onDone: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDone?() }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// MFMailComposeViewController wrapper. Check `MailComposer.canSend` before presenting.
struct MailComposer: UIViewControllerRepresentable {
    var to: [String]
    var subject: String
    var body: String
    var attachment: URL?
    var onDone: () -> Void

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(to)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let attachment, let data = try? Data(contentsOf: attachment) {
            let mime = attachment.pathExtension == "xlsx"
                ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                : "application/octet-stream"
            vc.addAttachmentData(data, mimeType: mime, fileName: attachment.lastPathComponent)
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            onDone()
        }
    }
}
