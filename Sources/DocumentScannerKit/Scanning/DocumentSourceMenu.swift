//
//  DocumentSourceMenu.swift
//  DocumentScannerKit
//
//  One menu, three sources, one field. Attach it to a "scan" button and the
//  user can scan a document, pick a PDF out of Files, or pick a photo out of
//  the library — all three read through the same parsers, all three fill the
//  same field, and a source that turns out not to carry the value says so
//  instead of quietly doing nothing.
//
//      // Once, on the screen that owns the field
//      private lazy var ibanMenu = DocumentSourceMenu(presenter: self, request: .iban)
//
//      // Wherever the button is configured
//      button.menu = ibanMenu.menu { [weak self] iban in
//          self?.ibanTextField.text = iban
//      }
//      button.showsMenuAsPrimaryAction = true
//
//  The menu owns its pickers and their delegates, so the host screen adopts
//  nothing. Titles are in `Appearance` (localize them there), and the two
//  places the kit would otherwise impose a look — the "not found" message
//  and the reading indicator — are overridable, so an app with its own
//  banner or HUD keeps its house style.
//

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
import PhotosUI

@MainActor
public final class DocumentSourceMenu: NSObject {

    /// Menu titles and the message the reading indicator shows. Localize
    /// here; the "no value found" copy lives on the `DocumentValueRequest`,
    /// since it is a property of the value, not of the menu.
    public struct Appearance {
        public var menuTitle: String
        public var scan: String
        public var document: String
        public var photoLibrary: String
        public var reading: String

        public init(menuTitle: String = "Select Option",
                    scan: String = "Scan",
                    document: String = "Document (PDF)",
                    photoLibrary: String = "Photo Library",
                    reading: String = "Reading") {
            self.menuTitle = menuTitle
            self.scan = scan
            self.document = document
            self.photoLibrary = photoLibrary
            self.reading = reading
        }
    }

    /// How "this document doesn't carry the value" reaches the user. Leave
    /// nil for a plain alert; set it to route through the app's own banner,
    /// toast or HUD.
    public var reportNotFound: ((String) -> Void)?

    /// Called with true while a picked file is being OCR'd and false when
    /// it finishes — a photo takes a moment and a multi-page PDF longer, and
    /// unlike the camera a pick has no UI of its own. Leave nil for the
    /// built-in indicator; set it to drive the app's own loader.
    public var setBusy: ((Bool) -> Void)?

    private weak var presenter: UIViewController?
    private let request: DocumentValueRequest
    private let appearance: Appearance

    /// Where the in-flight pick's value goes. Held only while a picker is up
    /// — its delegate callbacks arrive with no other context — and cleared
    /// the moment the pick resolves or is cancelled.
    private var pickCompletion: ((String) -> Void)?

    private lazy var indicator = ReadingIndicator()

    public init(presenter: UIViewController,
                request: DocumentValueRequest,
                appearance: Appearance = Appearance()) {
        self.presenter = presenter
        self.request = request
        self.appearance = appearance
    }

    /// The menu to hand a button's `menu` property (with
    /// `showsMenuAsPrimaryAction = true`). `found` receives the value; it
    /// does not fire when the user cancels or the source carries none.
    ///
    /// Safe to rebuild on every cell configuration — the menu holds no
    /// per-invocation state.
    public func menu(found: @escaping (String) -> Void) -> UIMenu {

        let children: [UIAction] = [

            UIAction(title: appearance.scan, image: UIImage(systemName: "crop")) { [weak self] _ in
                self?.scan(found: found)
            },
            UIAction(title: appearance.document, image: UIImage(systemName: "doc.text")) { [weak self] _ in
                self?.pickDocument(found: found)
            },
            UIAction(title: appearance.photoLibrary, image: UIImage(systemName: "photo")) { [weak self] _ in
                self?.pickPhoto(found: found)
            }
        ]

        let items = UIMenu(title: appearance.menuTitle, options: .displayInline, children: children)

        return UIMenu(title: appearance.menuTitle, children: [items])
    }

    // MARK: - The three sources

    private func scan(found: @escaping (String) -> Void) {

        guard let presenter else { return }

        DocumentScanner.presentValueScan(from: presenter, request: request) { [weak self] outcome in
            switch outcome {
            case .found(let value): found(value)
            case .notFound: self?.announceNotFound()
            case .cancelled: break
            }
        }
    }

    private func pickPhoto(found: @escaping (String) -> Void) {

        guard let presenter else { return }

        pickCompletion = found

        // PHPickerViewController, not UIImagePickerController's .photoLibrary
        // source: the legacy picker runs its whole browsing UI in-process —
        // Photos permission plus indexing the library before anything is
        // drawn — so it is visibly slow to open. PHPicker runs out-of-process
        // in a system-owned, pre-warmed extension and needs no permission.
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self

        presenter.present(picker, animated: true)
    }

    private func pickDocument(found: @escaping (String) -> Void) {

        guard let presenter else { return }

        pickCompletion = found

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf], asCopy: true)
        picker.delegate = self

        presenter.present(picker, animated: true)
    }

    // MARK: - Reading the pick

    /// Both pickers land here: OCR the file, hand back the value it carries,
    /// and say so plainly when it carries none.
    private func read(image: UIImage?, pdfFilePath: URL?) {

        let completion = pickCompletion
        pickCompletion = nil

        updateBusy(true)

        DocumentReader.readValue(image: image, pdfFilePath: pdfFilePath, request: request) { [weak self] value in

            self?.updateBusy(false)

            guard let value else {
                self?.announceNotFound()
                return
            }

            completion?(value)
        }
    }

    private func updateBusy(_ busy: Bool) {

        if let setBusy {
            setBusy(busy)
        }
        else if busy, let view = presenter?.view {
            indicator.show(in: view, message: appearance.reading)
        }
        else {
            indicator.hide()
        }
    }

    private func announceNotFound() {

        if let reportNotFound {
            reportNotFound(request.notFoundMessage)
            return
        }

        let alert = UIAlertController(title: nil, message: request.notFoundMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }
}

// MARK: - PHPicker Delegate

extension DocumentSourceMenu: PHPickerViewControllerDelegate {

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {

        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            pickCompletion = nil
            picker.dismiss(animated: true)
            return
        }

        provider.loadObject(ofClass: UIImage.self) { [weak self] image, _ in
            DispatchQueue.main.async {
                // Read after the picker is gone, so the indicator has a view
                // to show in and the alert has somewhere to present from.
                picker.dismiss(animated: true) {
                    self?.read(image: image as? UIImage, pdfFilePath: nil)
                }
            }
        }
    }
}

// MARK: - DocumentPicker Delegate

extension DocumentSourceMenu: UIDocumentPickerDelegate {

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {

        guard let fileUrl = urls.first else {
            pickCompletion = nil
            return
        }

        read(image: nil, pdfFilePath: fileUrl)
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {

        pickCompletion = nil
    }
}

// MARK: - The built-in reading indicator

/// A deliberately plain "working on it" overlay — enough that a pick never
/// looks frozen, and easy to replace: set `DocumentSourceMenu.setBusy` and
/// this never appears.
private final class ReadingIndicator {

    private var overlay: UIView?

    func show(in view: UIView, message: String) {

        hide()

        let backdrop = UIView()
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let panel = UIView()
        panel.backgroundColor = UIColor.secondarySystemBackground
        panel.layer.cornerRadius = 12
        panel.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(stack)
        backdrop.addSubview(panel)
        view.addSubview(backdrop)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            panel.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
        ])

        overlay = backdrop
    }

    func hide() {
        overlay?.removeFromSuperview()
        overlay = nil
    }
}
#endif
