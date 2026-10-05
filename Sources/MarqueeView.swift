import AppKit

/// A red bar with text scrolling right-to-left, forever.
///
/// The text is laid out once into a single wide layer holding N copies of the
/// message, then that layer is slid left by exactly one copy's width on an infinite
/// `CABasicAnimation`. Because the animation runs on the render server the scroll
/// costs no per-frame CPU, and because the shift is exactly one copy wide the loop
/// point is invisible.
final class MarqueeView: NSView {

    var text: String = "LIVE ON AIR" {
        didSet { if text != oldValue { rebuild() } }
    }

    private let clipLayer = CALayer()
    private let scrollLayer = CALayer()
    private let textLayer = CATextLayer()
    private let hairlineLayer = CALayer()

    private static let animationKey = "marquee"
    private var copyWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Layer-hosting: assign the layer first, then opt in. The reverse order makes
        // this merely layer-backed and AppKit may clear our sublayers on redraw.
        let root = CALayer()
        layer = root
        wantsLayer = true

        root.backgroundColor = NSColor(srgbRed: 0.85, green: 0.05, blue: 0.08, alpha: 1).cgColor
        root.masksToBounds = true

        // A slightly brighter hairline along the top edge so the bar reads as a
        // deliberate object rather than a rendering glitch on a dark desktop.
        hairlineLayer.backgroundColor = NSColor(srgbRed: 1, green: 0.35, blue: 0.35, alpha: 0.9).cgColor
        root.addSublayer(hairlineLayer)

        clipLayer.masksToBounds = true
        root.addSublayer(clipLayer)

        textLayer.truncationMode = .none
        textLayer.isWrapped = false
        textLayer.alignmentMode = .left
        scrollLayer.addSublayer(textLayer)
        clipLayer.addSublayer(scrollLayer)
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    /// The repeating unit: the message, a bullet, and breathing room either side.
    private var unitString: String {
        "\(text)   \u{25CF}   "
    }

    private func attributes(for height: CGFloat) -> [NSAttributedString.Key: Any] {
        let size = max(9, (height * 0.58).rounded())
        return [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: size * 0.12,
        ]
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = window?.backingScaleFactor ?? 2
        let attrs = attributes(for: bounds.height)
        let unit = NSAttributedString(string: unitString.uppercased(), attributes: attrs)
        let unitWidth = ceil(unit.size().width)
        guard unitWidth > 0 else { return }

        // Enough copies to cover the bar plus one full copy to slide away.
        let copies = max(2, Int(ceil((bounds.width + unitWidth) / unitWidth)) + 1)
        let full = NSMutableAttributedString()
        for _ in 0..<copies { full.append(unit) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        hairlineLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        clipLayer.frame = bounds

        let totalWidth = unitWidth * CGFloat(copies)
        scrollLayer.frame = CGRect(x: 0, y: 0, width: totalWidth, height: bounds.height)

        textLayer.contentsScale = scale
        textLayer.string = full
        let textHeight = ceil(unit.size().height)
        textLayer.frame = CGRect(
            x: 0,
            y: ((bounds.height - textHeight) / 2).rounded(),
            width: totalWidth,
            height: textHeight)

        CATransaction.commit()

        // Only restart the animation if the geometry actually changed, so a relayout
        // does not visibly jump the text back to its starting position.
        if abs(copyWidth - unitWidth) > 0.5 || scrollLayer.animation(forKey: Self.animationKey) == nil {
            copyWidth = unitWidth
            startScrolling(by: unitWidth)
        }
    }

    private func startScrolling(by distance: CGFloat) {
        scrollLayer.removeAnimation(forKey: Self.animationKey)

        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -distance
        animation.duration = CFTimeInterval(distance / Prefs.speed)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        // A ProMotion display would otherwise recomposite the bar 120 times a second
        // for as long as you are live. 60 is indistinguishable for scrolling text.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        scrollLayer.add(animation, forKey: Self.animationKey)
    }

    /// Restart from scratch, e.g. after the scroll speed preference changes.
    func restart() {
        copyWidth = 0
        rebuild()
    }
}
