import SwiftUI
import FluidStreamBenchmarkKit

/// The baseline renderer (RFC-004): re-parse the whole Markdown string and re-lay-out the
/// whole `Text` on every network packet, then scroll to the bottom.
///
/// This is intentionally the straightforward version a good engineer would write first.
/// It's not a strawman.
struct NaivePane: View {
    let model: NaiveStreamModel
    var onScrollActivityChanged: ((Bool) -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(rendered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottom)
            }
            .onChange(of: model.text) {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
            .modifier(ScrollActivityReporter(onChange: onScrollActivityChanged))
        }
    }

    private static let bottom = "bottom"

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: model.text, options: options)) ?? AttributedString(model.text)
    }
}

/// Reports user scrolls of a SwiftUI `ScrollView`, matching `StreamTextView.onScrollActivityChanged`:
/// `true` while the content moves under a finger or decelerates afterwards. Programmatic
/// scrolls (phase `.animating`) and a touch that doesn't move (`.tracking`) don't count.
/// `onScrollPhaseChange` needs iOS 18; on iOS 17 the naive pane reports no scrolls.
private struct ScrollActivityReporter: ViewModifier {
    let onChange: ((Bool) -> Void)?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                onChange?(phase == .interacting || phase == .decelerating)
            }
        } else {
            content
        }
    }
}
