import AppKit

@MainActor
final class PasteProgress {
  private var panel: NSPanel?
  private var showTask: Task<Void, Never>?
  private var fraction: Double?
  private var closed = false
  private let subtitle = NSTextField(labelWithString: "Connecting to Portside…")
  private let indicator = NSProgressIndicator()

  init() {
    // Fast uploads already give feedback by inserting their path immediately.
    showTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      self?.show()
    }
  }

  func update(_ value: Double) {
    guard !closed, value.isFinite else { return }
    fraction = max(fraction ?? 0, min(1, value))
    if panel != nil { refresh() }
  }

  func close() {
    closed = true
    showTask?.cancel()
    indicator.stopAnimation(nil)
    panel?.orderOut(nil)
    panel = nil
  }

  private func refresh() {
    if let fraction {
      indicator.stopAnimation(nil)
      indicator.isIndeterminate = false
      indicator.doubleValue = fraction
      subtitle.stringValue =
        fraction >= 1
        ? "Saving on the server…" : "\(Int(fraction * 100))% sent"
    } else {
      indicator.isIndeterminate = true
      indicator.startAnimation(nil)
    }
  }

  private func show() {
    guard !closed,
      let screen = NSScreen.screens.first(where: {
        $0.frame.contains(NSEvent.mouseLocation)
      }) ?? NSScreen.main
    else { return }
    let frame = screen.visibleFrame
    let rect = NSRect(x: frame.maxX - 306, y: frame.maxY - 110, width: 286, height: 90)
    let window = NSPanel(
      contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false, screen: screen)
    window.setFrame(rect, display: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .floating
    window.hidesOnDeactivate = false
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    window.title = "Portside image upload"

    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: rect.size))
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 14
    background.layer?.masksToBounds = true
    let title = NSTextField(labelWithString: "Uploading image")
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    indicator.style = .bar
    indicator.controlSize = .small
    indicator.minValue = 0
    indicator.maxValue = 1
    indicator.setAccessibilityLabel("Image upload progress")

    let stack = NSStackView(views: [title, subtitle, indicator])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
      stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
      indicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    window.contentView = background
    panel = window
    refresh()
    window.orderFrontRegardless()
  }
}
