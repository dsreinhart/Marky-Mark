//
//  PadKeyboardBar.swift
//  Markwright iPad
//
//  On a phone-width screen the formatting strip rides on top of the keyboard instead of
//  sitting under the title: it is there while typing and gone, with the keyboard, while reading.
//  Both editors share one bar as their input accessory view.
//

import SwiftUI
import UIKit

@MainActor
final class PadKeyboardBar {
    static let height: CGFloat = 50

    /// The view the editors use as `inputAccessoryView`: clear, so the bar's glass capsule floats
    /// above the keyboard as the system's own keyboard bars do.
    let view: UIView
    private let host: UIHostingController<PadFormattingToolbar>

    init(toolbar: PadFormattingToolbar) {
        host = UIHostingController(rootView: toolbar)
        host.sizingOptions = []
        // The bar sits just above the keyboard, so the screen's bottom safe area doesn't apply to
        // it. Left on, SwiftUI shifted the capsule up out of the bar's frame, over the line being
        // typed (the text view stops at the frame's top edge).
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height))
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth]
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension UITextView {
    /// Shows `accessory` above the keyboard (nil for none), refreshing the keyboard if it is up.
    func setKeyboardAccessory(_ accessory: UIView?) {
        guard inputAccessoryView !== accessory else { return }
        inputAccessoryView = accessory
        if isFirstResponder { reloadInputViews() }
    }
}
