import SwiftUI
import AppKit

enum Brand {
    static let name = "Think Out Loud"
    static let settingsSize = NSSize(width: 520, height: 630)
    static func panelSize(failed: Bool) -> NSSize {
        failed ? NSSize(width: 380, height: 180) : NSSize(width: 244, height: 48)
    }
}

// Approved concept 6: voice bars, insertion cursor and written line.
struct ThinkOutLoudSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, y, w, h, radius) in [
            (0.02, 0.33, 0.14, 0.32, 0.07),
            (0.23, 0.20, 0.14, 0.58, 0.07),
            (0.47, 0.08, 0.07, 0.79, 0.02),
            (0.41, 0.04, 0.19, 0.04, 0.02),
            (0.41, 0.87, 0.19, 0.04, 0.02),
            (0.64, 0.78, 0.34, 0.07, 0.035)
        ] {
            path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: radius, height: radius))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct BrandMark: View {
    var size: CGFloat = 36
    var body: some View {
        ThinkOutLoudSymbol().fill(.primary).frame(width: size, height: size)
            .accessibilityLabel(Brand.name)
    }
}

enum Palette {
    static let background = Color.white
    static let ink = Color.black
    static let muted = Color.black.opacity(0.55)
    static let border = Color.black.opacity(0.12)
    static let surface = Color(white: 0.97)
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(configuration.isPressed ? Color(white: 0.90) : Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.border))
    }
}

struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Button { configuration.isOn.toggle() } label: {
                Circle().fill(.white).frame(width: 16, height: 16)
                    .frame(width: 32, height: 20, alignment: configuration.isOn ? .trailing : .leading)
                    .padding(.horizontal, 2)
                    .background(configuration.isOn ? Color.black : Color(white: 0.75), in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("Play a sound when text is copied")
                .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

func brandMenuIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 20, height: 18))
    image.lockFocus()
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: 18)
    context.scaleBy(x: 1, y: -1)
    context.addPath(ThinkOutLoudSymbol().path(in: CGRect(x: 1, y: 1, width: 18, height: 16)).cgPath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    image.unlockFocus()
    image.isTemplate = true
    image.accessibilityDescription = Brand.name
    return image
}
