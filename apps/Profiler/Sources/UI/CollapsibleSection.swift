import SwiftUI

/// A sidebar section that uses the system's collapsible section chrome on macOS and an
/// equivalent compact, tappable section header on iOS.
///
/// SwiftUI accepts `Section(isExpanded:)` on both platforms, but only macOS gives it the
/// source-list disclosure treatment. Keeping the fallback here prevents every sidebar
/// from growing its own slightly different iOS header.
struct CollapsibleListSection<Content: View, Header: View>: View {
    @Binding private var isExpanded: Bool
    private let content: Content
    private let header: Header

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) {
        _isExpanded = isExpanded
        self.content = content()
        self.header = header()
    }

    var body: some View {
        #if os(macOS)
        Section(isExpanded: $isExpanded) {
            content
        } header: {
            header
        }
        #else
        Section {
            if isExpanded {
                content
            }
        } header: {
            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    header
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        #endif
    }
}

extension Binding {
    /// Membership in a set, as a `Bool` binding: `$expanded[contains: .source]`.
    ///
    /// Collapsible `Section`s each want their own `Binding<Bool>`, which would otherwise mean
    /// one `@State` property per section. Holding the open sections in a single set keeps the
    /// state in one place and makes the default — which sections start open — a single literal.
    subscript<Element: Hashable>(contains element: Element) -> Binding<Bool>
    where Value == Set<Element> {
        Binding<Bool>(
            get: { wrappedValue.contains(element) },
            set: { isExpanded in
                if isExpanded {
                    wrappedValue.insert(element)
                } else {
                    wrappedValue.remove(element)
                }
            }
        )
    }
}
