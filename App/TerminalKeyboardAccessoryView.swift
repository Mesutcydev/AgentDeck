//
//  TerminalKeyboardAccessoryView.swift
//  App — AgentDeck
//
//  §29 Phase 5 keyboard accessory with Control, Escape, and Paste keys.
//

import UIKit

final class TerminalKeyboardAccessoryView: UIView {
    init(onControl: @escaping () -> Void, onEscape: @escaping () -> Void, onPaste: @escaping () -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemBackground

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let control = UIButton(type: .system)
        control.setTitle("Control", for: .normal)
        control.addAction(UIAction { _ in onControl() }, for: .touchUpInside)

        let escape = UIButton(type: .system)
        escape.setTitle("Escape", for: .normal)
        escape.addAction(UIAction { _ in onEscape() }, for: .touchUpInside)

        let paste = UIButton(type: .system)
        paste.setTitle("Paste", for: .normal)
        paste.addAction(UIAction { _ in onPaste() }, for: .touchUpInside)

        stack.addArrangedSubview(control)
        stack.addArrangedSubview(escape)
        stack.addArrangedSubview(paste)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
