import AppKit
import SwiftUI

struct SplitSizing {
    static func first(available: CGFloat, fraction: Double, minimumFirst: CGFloat, minimumSecond: CGFloat) -> CGFloat {
        let available = max(0, available)
        let lower = min(minimumFirst, available / 2)
        let upper = max(lower, available - min(minimumSecond, available / 2))
        return min(upper, max(lower, available * (fraction.isFinite ? fraction : 0.5)))
    }
}

struct ResizableSplit<First: View, Second: View>: View {
    let horizontal: Bool
    let minimumFirst: CGFloat
    let minimumSecond: CGFloat
    var secondVisible = true
    @AppStorage private var fraction: Double
    @State private var dragOrigin: CGFloat?
    @State private var hovering = false
    private let first: First
    private let second: Second

    init(horizontal: Bool, key: String, minimumFirst: CGFloat, minimumSecond: CGFloat,
         secondVisible: Bool = true, @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.horizontal = horizontal
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
        self.secondVisible = secondVisible
        _fraction = AppStorage(wrappedValue: 0.5, key)
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, (horizontal ? geometry.size.width : geometry.size.height) - (secondVisible ? 12 : 0))
            let position = SplitSizing.first(available: available, fraction: fraction,
                minimumFirst: minimumFirst, minimumSecond: minimumSecond)
            let firstSpan = secondVisible ? position : available
            ZStack(alignment: .topLeading) {
                first
                    .frame(width: horizontal ? firstSpan : geometry.size.width,
                           height: horizontal ? geometry.size.height : firstSpan)
                    .clipped()
                if secondVisible {
                    handle(available: available, position: position)
                        .frame(width: horizontal ? 12 : geometry.size.width,
                               height: horizontal ? geometry.size.height : 12)
                        .offset(x: horizontal ? position : 0, y: horizontal ? 0 : position)
                    second
                        .frame(width: horizontal ? available - position : geometry.size.width,
                               height: horizontal ? geometry.size.height : available - position)
                        .clipped()
                        .offset(x: horizontal ? position + 12 : 0, y: horizontal ? 0 : position + 12)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func handle(available: CGFloat, position: CGFloat) -> some View {
        ZStack {
            Color(nsColor: .separatorColor).opacity(hovering || dragOrigin != nil ? 0.45 : 0.2)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(horizontal ? 90 : 0))
                .foregroundStyle(.secondary)
        }
        .frame(width: horizontal ? 12 : nil, height: horizontal ? nil : 12)
        .contentShape(Rectangle())
        .onHover { value in
            hovering = value
            (value ? (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
            if dragOrigin == nil { dragOrigin = position }
            let delta = horizontal ? value.translation.width : value.translation.height
            let proposed = ((dragOrigin ?? position) + delta) / max(1, available)
            fraction = Double(SplitSizing.first(available: available, fraction: Double(proposed),
                minimumFirst: minimumFirst, minimumSecond: minimumSecond) / max(1, available))
        }.onEnded { _ in dragOrigin = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { fraction = 0.5 })
        .help(horizontal ? "Drag to resize research; double-click to reset" : "Drag to resize transcript and questions; double-click to reset")
        .accessibilityLabel(horizontal ? "Research width divider" : "Transcript and questions divider")
        .accessibilityValue("\(Int(fraction * 100))%")
        .accessibilityAdjustableAction { direction in
            fraction = min(0.9, max(0.1, fraction + (direction == .increment ? 0.05 : -0.05)))
        }
    }
}
