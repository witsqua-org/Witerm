import SwiftUI

/// The three sheet widths (Mac). Each fits its content's height up to a
/// maximum, unless a flow fixes it so its steps never resize the sheet.
enum SheetWidth {
    case compact, form, flow

    var points: CGFloat {
        switch self {
        case .compact: 400
        case .form: 520
        case .flow: 600
        }
    }
}

/// One shape for every sheet: a title, one scrolling area, a divider, and a
/// footer. Destructive and secondary actions go in `leading`; Cancel (with
/// `.cancelAction`) and the primary (with `.defaultAction`, unless it's a
/// trust decision) go in `trailing`, primary last. Esc always cancels: give
/// a sheet without a Cancel button an `onEscape`. Footer controls keep the
/// system's regular size and bezel, and the sheet adds no tint, so switches,
/// radios and checkboxes keep the system accent. iOS shows the same parts in
/// a navigation stack.
struct SheetScaffold<Header: View, Content: View, Leading: View, Trailing: View>: View {
    let title: String?
    let subtitle: String?
    let width: SheetWidth
    /// A fixed height for multi-step flows; nil fits the content up to `maxHeight`.
    let height: CGFloat?
    let maxHeight: CGFloat
    /// False when the content scrolls itself (a table), so the sheet doesn't wrap it.
    let scrolls: Bool
    let onEscape: (() -> Void)?
    let content: Content
    let header: Header
    let leading: Leading
    let trailing: Trailing

    init(_ title: String?, subtitle: String? = nil, width: SheetWidth = .form, height: CGFloat? = nil,
         maxHeight: CGFloat = 640, scrolls: Bool = true, onEscape: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content,
         @ViewBuilder header: () -> Header = { EmptyView() },
         @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.height = height
        self.maxHeight = maxHeight
        self.scrolls = scrolls
        self.onEscape = onEscape
        self.content = content()
        self.header = header()
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            titleBlock
            scrollingArea(fixed: height != nil)
            Divider()
            HStack(spacing: WitermMetrics.Space.s) {
                leading
                Spacer(minLength: WitermMetrics.Space.s)
                trailing
            }
            .controlSize(.regular)
            .padding(.horizontal, WitermMetrics.sheetInset)
            .padding(.vertical, WitermMetrics.Space.m)
        }
        .frame(width: width.points, height: height)
        .background(WitermTheme.surface)
        .onExitCommand { onEscape?() }
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WitermMetrics.Space.m) {
                    header
                    content
                }
                .padding(WitermMetrics.sheetInset)
            }
            .navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack { leading; Spacer(); trailing }
                    .padding(WitermMetrics.sheetInset)
                    .background(.bar)
            }
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder private var titleBlock: some View {
        if title != nil || Header.self != EmptyView.self {
            VStack(alignment: .leading, spacing: WitermMetrics.Space.xs) {
                header
                if let title {
                    Text(title)
                        .font(WitermType.pageTitle)
                        .foregroundStyle(WitermTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(WitermType.rowDetail)
                        .foregroundStyle(WitermTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WitermMetrics.sheetInset)
            .padding(.top, WitermMetrics.Space.xl)
            .padding(.bottom, WitermMetrics.Space.m)
        }
    }

    private var padded: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WitermMetrics.sheetInset)
            .padding(.top, title == nil ? WitermMetrics.Space.xl : 0)
            .padding(.bottom, WitermMetrics.Space.l)
    }

    /// A fixed sheet scrolls its content; a fitting one shows the content at
    /// its own height and scrolls only past `maxHeight`, so the sheet is
    /// never taller than what it holds.
    @ViewBuilder private func scrollingArea(fixed: Bool) -> some View {
        if !scrolls {
            padded.frame(maxHeight: .infinity, alignment: .top)
        } else if fixed {
            ScrollView { padded }
                .frame(maxHeight: .infinity)
        } else {
            ViewThatFits(in: .vertical) {
                padded.fixedSize(horizontal: false, vertical: true)
                ScrollView { padded }
            }
            .frame(maxHeight: maxHeight)
        }
    }
    #endif
}
