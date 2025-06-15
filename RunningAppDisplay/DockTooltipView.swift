import Cocoa

class DockTooltipView: NSView {
    private let label: NSTextField
    private let backgroundView: NSVisualEffectView
    private let arrowHeight: CGFloat = 8
    private let cornerRadius: CGFloat = 6
    private let padding: CGFloat = 8
    
    init(text: String) {
        // Create the background blur view
        backgroundView = NSVisualEffectView()
        backgroundView.material = .hudWindow
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        
        // Create the label
        label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        
        // Calculate frame based on text
        let labelSize = label.sizeThatFits(NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let width = labelSize.width + (padding * 2)
        let height = labelSize.height + (padding * 2) + arrowHeight
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        
        // Add and position subviews
        addSubview(backgroundView)
        addSubview(label)
        
        // Configure view
        wantsLayer = true
        layer?.masksToBounds = false
        
        // Position subviews
        backgroundView.frame = bounds
        label.frame = NSRect(
            x: padding,
            y: padding + arrowHeight,
            width: width - (padding * 2),
            height: labelSize.height
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateText(_ text: String) {
        label.stringValue = text
        
        // Recalculate size
        let labelSize = label.sizeThatFits(NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let width = labelSize.width + (padding * 2)
        let height = labelSize.height + (padding * 2) + arrowHeight
        
        // Update frames
        frame = NSRect(x: frame.minX, y: frame.minY, width: width, height: height)
        backgroundView.frame = bounds
        label.frame = NSRect(
            x: padding,
            y: padding + arrowHeight,
            width: width - (padding * 2),
            height: labelSize.height
        )
        
        // Force redraw of the background shape
        setNeedsDisplay(bounds)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        // Create path for rounded rectangle with arrow
        let path = NSBezierPath()
        
        // Start at bottom center (arrow tip)
        path.move(to: NSPoint(x: bounds.midX, y: 0))
        
        // Draw arrow to bottom left of rounded rect
        path.line(to: NSPoint(x: bounds.midX - arrowHeight, y: arrowHeight))
        
        // Draw rounded rectangle
        let rectBounds = NSRect(x: 0, y: arrowHeight, width: bounds.width, height: bounds.height - arrowHeight)
        let roundedRect = NSBezierPath(roundedRect: rectBounds, xRadius: cornerRadius, yRadius: cornerRadius)
        path.append(roundedRect)
        
        // Draw arrow to bottom right
        path.line(to: NSPoint(x: bounds.midX + arrowHeight, y: arrowHeight))
        path.line(to: NSPoint(x: bounds.midX, y: 0))
        
        // Close the path
        path.close()
        
        // Set the path as the mask for the background view
        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        backgroundView.layer?.mask = maskLayer
    }
}

// Window to host the tooltip view
class DockTooltipWindow: NSWindow {
    private var tooltipView: DockTooltipView
    private static var sharedWindow: DockTooltipWindow?
    
    static func getSharedWindow() -> DockTooltipWindow {
        if let window = sharedWindow {
            return window
        }
        let window = DockTooltipWindow(text: "")
        window.orderFront(nil)  // Make sure window is in front
        window.alphaValue = 0   // But invisible initially
        sharedWindow = window
        return window
    }
    
    init(text: String) {
        tooltipView = DockTooltipView(text: text)
        
        super.init(
            contentRect: tooltipView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        contentView = tooltipView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating + 1  // Make sure it's above other UI elements
        isReleasedWhenClosed = false
        ignoresMouseEvents = true  // Let mouse events pass through
    }
    
    func updateText(_ text: String) {
        tooltipView.updateText(text)
        setFrame(tooltipView.frame, display: true)
        // Make sure window is front after text update
        orderFront(nil)
    }
    
    deinit {
        if self === DockTooltipWindow.sharedWindow {
            DockTooltipWindow.sharedWindow = nil
        }
    }
} 