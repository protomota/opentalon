import CloudKit
import CompanionCore
import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

private struct PhoneColorsKey: EnvironmentKey {
    static let defaultValue = OpenTalonColors(theme: .light)
}

extension EnvironmentValues {
    var phoneColors: OpenTalonColors {
        get { self[PhoneColorsKey.self] }
        set { self[PhoneColorsKey.self] = newValue }
    }
}

struct PhoneActionLabel: View {
    @Environment(\.phoneColors) private var colors
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title).foregroundStyle(colors.text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(colors.actionAccent)
        }
    }
}

struct PhoneActionButtonStyle: ButtonStyle {
    @Environment(\.phoneColors) private var colors
    @Environment(\.isEnabled) private var enabled
    var horizontalPadding: CGFloat = 14
    var circular = false
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        let accent = configuration.role == .destructive ? colors.danger : colors.actionAccent
        return configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(configuration.role == .destructive ? colors.danger : colors.text)
            .padding(.horizontal, circular ? 0 : horizontalPadding)
            .padding(.vertical, circular ? 0 : 8)
            .frame(width: circular ? 44 : nil, height: circular ? 44 : nil)
            .frame(minWidth: 44, minHeight: 44)
            .background {
                shape.fill(configuration.isPressed ? colors.canvas : colors.card)
                if emphasized { shape.fill(accent.opacity(configuration.isPressed ? 0.20 : 0.10)) }
            }
            .overlay {
                shape.strokeBorder(emphasized ? accent.opacity(0.55) : colors.line)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.48)
    }
}

struct PhoneActionToolbarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem(placement: placement) {
            content().buttonStyle(PhoneActionButtonStyle())
        }
    }
}

extension View {
    func phoneConfirmation(_ title: String, isPresented: Binding<Bool>, message: String,
                           confirm: String, cancel: String? = "Cancel", role: ButtonRole? = nil,
                           confirmID: String = "phoneConfirmAction", action: @escaping () -> Void) -> some View {
        modifier(PhoneConfirmation(isPresented: isPresented, title: title, message: message, confirm: confirm,
                                   cancel: cancel, role: role, confirmID: confirmID, action: action))
    }
}

private struct PhoneConfirmation: ViewModifier {
    @Environment(\.phoneColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var coverPresented = false
    @State private var visible = false
    @State private var closing = false

    @Binding var isPresented: Bool
    let title: String
    let message: String
    let confirm: String
    let cancel: String?
    let role: ButtonRole?
    let confirmID: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $coverPresented) {
                dialog.presentationBackground(.clear)
            }
            .onChange(of: isPresented) {
                setCoverPresented(isPresented)
            }
    }

    private var dialog: some View {
        ZStack {
            Color.black.opacity(visible ? 0.30 : 0)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            ViewThatFits(in: .vertical) {
                panel.fixedSize(horizontal: false, vertical: true)
                ScrollView { panel }
            }
            .frame(maxWidth: 370)
            .padding(20)
            .scaleEffect(visible || reduceMotion ? 1 : 0.96)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible && !closing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityAction(.escape) { close() }
        .task {
            await Task.yield()
            guard !Task.isCancelled, !closing else { return }
            withAnimation(.easeOut(duration: 0.18)) { visible = true }
            titleFocused = true
        }
    }

    private func setCoverPresented(_ presented: Bool) {
        guard coverPresented != presented else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !presented { visible = false }
            coverPresented = presented
        }
    }

    private func close(confirming: Bool = false) {
        guard !closing else { return }
        closing = true
        withAnimation(.easeIn(duration: 0.14)) {
            visible = false
        } completion: {
            setCoverPresented(false)
            isPresented = false
            closing = false
            if confirming { action() }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(colors.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(colors.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .trailing, spacing: 8) { buttons }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.canvas, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(colors.line).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        if let cancel {
            Button(cancel, role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(PhoneActionButtonStyle())
        }
        Button(confirm, role: role) { close(confirming: true) }
        .buttonStyle(PhoneActionButtonStyle(emphasized: cancel != nil))
        .accessibilityIdentifier(confirmID)
    }
}

private struct PhoneListAppearance: ViewModifier {
    @Environment(\.phoneColors) private var colors
    var background: Color? = nil

    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background(background ?? colors.canvas)
    }
}

private struct PhoneReviewPrompt: ViewModifier {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var phase
    @State private var visible = false

    let isSelected: Bool

    private var canRequestReview: Bool {
        visible && isSelected && phase == .active && workspace.snapshot != nil
            && workspace.canRequestAppStoreReview && workspace.reviewMilestone.isDue
    }

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: canRequestReview) {
                guard canRequestReview else { return }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled, canRequestReview, workspace.reviewMilestone.takeRequest() else { return }
                requestReview()
            }
    }
}

@main
struct OpenTalonPhone: App {
    @UIApplicationDelegateAdaptor(PhoneNotificationDelegate.self) private var notificationDelegate
    @State private var workspace = PhoneWorkspace()
    @State private var tips = PhoneTips()
    @Environment(\.scenePhase) private var phase
    @AppStorage("appearanceTheme") private var theme = OpenTalonTheme.system

    var body: some Scene {
        WindowGroup {
            CompanionHome()
                .environment(workspace)
                .environment(tips)
                .preferredColorScheme(theme.colorScheme)
                .task { await tips.observeTransactions() }
                .task(id: phase) {
                    guard phase == .active else { return }
                    await workspace.checkAppStoreInstall()
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    workspace.accountDidChange()
                }
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        await workspace.sync()
                        do { try await Task.sleep(for: .seconds(15)) }
                        catch { return }
                    }
                }
        }
    }
}

private final class PhoneNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

struct CompanionHome: View {
    private enum Page { case today, projects, queue, settings }

    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("appearanceTheme") private var theme = OpenTalonTheme.system
    @State private var quickAdd = false
    @State private var page = Page.today

    var body: some View {
        let colors = OpenTalonColors(theme: theme, systemScheme: systemScheme)
        TabView(selection: $page) {
            NavigationStack {
                if workspace.snapshot != nil {
                    TodayView()
                        .navigationTitle("Today")
                        .toolbar { controls }
                        .modifier(PhoneReviewPrompt(isSelected: page == .today && !quickAdd))
                } else {
                    syncUnavailable(colors: colors)
                }
            }
            .tint(colors.text)
            .tabItem { tabLabel("Today", systemImage: "sun.max", destination: .today, colors: colors) }
            .tag(Page.today)

            NavigationStack {
                if workspace.snapshot == nil {
                    syncUnavailable(colors: colors)
                } else {
                    ProjectsView()
                        .navigationTitle("Projects")
                        .toolbar { controls }
                        .modifier(PhoneReviewPrompt(isSelected: page == .projects && !quickAdd))
                }
            }
            .tint(colors.text)
            .tabItem { tabLabel("Projects", systemImage: "square.grid.2x2", destination: .projects, colors: colors) }
            .tag(Page.projects)

            NavigationStack {
                QueueView()
                    .navigationTitle("Queue")
                    .toolbar { controls }
                    .modifier(PhoneReviewPrompt(isSelected: page == .queue && !quickAdd))
            }
            .tint(colors.text)
            .tabItem { tabLabel("Queue", systemImage: "paperplane", destination: .queue, colors: colors) }
            .tag(Page.queue)
            .badge(workspace.pending.count)

            NavigationStack {
                SyncSettingsView()
                    .navigationTitle("Settings")
            }
            .tint(colors.text)
            .tabItem { tabLabel("Settings", systemImage: "gearshape", destination: .settings, colors: colors) }
            .tag(Page.settings)
        }
        .sheet(isPresented: $quickAdd) { CaptureView().tint(colors.text) }
        .environment(\.phoneColors, colors)
        .tint(colors.actionAccent)
    }

    private func tabLabel(_ title: LocalizedStringKey, systemImage: String, destination: Page,
                          colors: OpenTalonColors) -> some View {
        let neutral: Color = (theme.colorScheme ?? systemScheme) == .dark ? .white : .black
        let color = page == destination ? colors.actionAccent : neutral
        return Label {
            Text(title)
        } icon: {
            if let symbol = UIImage(systemName: systemImage) {
                Image(uiImage: symbol.withTintColor(UIColor(color), renderingMode: .alwaysOriginal))
            } else {
                Image(systemName: systemImage)
            }
        }
    }

    private func syncUnavailable(colors: OpenTalonColors) -> some View {
        ContentUnavailableView {
            if workspace.syncError != nil, !workspace.syncing {
                Label("iCloud needs attention", systemImage: "exclamationmark.icloud")
            } else {
                Label("Syncing your workspace", systemImage: "icloud")
            }
        } description: {
            VStack(spacing: 8) {
                if let error = workspace.syncError, !workspace.syncing {
                    Text(error)
                } else {
                    Text("Your first sync can take a few minutes if you have a lot of tasks. You can use other tabs while it runs. If you leave the app, it checks again when you return.")
                    if workspace.remoteWorkspaceFound == false {
                        Text("Still waiting for your Mac to publish its workspace. Check iCloud Sync in Settings on your Mac.")
                    }
                }
            }
        } actions: {
            VStack(spacing: 14) {
                if workspace.syncing {
                    ProgressView().accessibilityLabel("Checking iCloud")
                }
                Button("Check Sync Settings") { page = .settings }
                    .buttonStyle(PhoneActionButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.canvas.ignoresSafeArea())
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        PhoneActionToolbarItem(placement: .primaryAction) {
            Button {
                quickAdd = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(OpenTalonColors(theme: theme, systemScheme: systemScheme).actionAccent)
            }
            .buttonStyle(PhoneActionButtonStyle(circular: true))
            .accessibilityLabel("New task")
            .disabled(workspace.snapshot?.projects.isEmpty != false)
        }
    }
}

private struct SyncSettingsView: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(PhoneTips.self) private var tips
    @Environment(\.phoneColors) private var colors
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearanceTheme") private var theme = OpenTalonTheme.system
    @State private var showTips = false
    @State private var showTechnicalSupport = false
    @AppStorage(PhoneWorkspace.pickupAlertsKey) private var pickupAlerts = false
    @State private var notificationDenied = false

    private var settingsBackground: Color {
        if theme == .light || (theme == .system && colorScheme == .light) {
            return Color(red: 237.0 / 255, green: 240.0 / 255, blue: 243.0 / 255)
        }
        return colors.canvas
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 640 && !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 20) {
                    Form {
                        syncSection
                        diagnosticsSection
                        trashSection
                    }
                    Form {
                        appearanceSection
                        helpSection
                        supportSection
                        aboutSection
                        productUpdatesSection
                    }
                }
            } else {
                Form {
                    appearanceSection
                    syncSection
                    diagnosticsSection
                    trashSection
                    helpSection
                    supportSection
                    aboutSection
                    productUpdatesSection
                }
            }
        }
        .modifier(PhoneListAppearance(background: settingsBackground))
        .sheet(isPresented: $showTips) { PhoneTipSheet() }
        .sheet(isPresented: $showTechnicalSupport) { OpenTalonSupportTicketsView() }
    }

    private var trashSection: some View {
        Section {
            NavigationLink {
                PhoneTrashView()
            } label: {
                PhoneActionLabel(title: "Trash", systemImage: "trash")
            }
        }
        .listRowBackground(colors.card)
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            ForEach([OpenTalonTheme.paper, .graphite, .light, .system]) { choice in
                themeRow(choice)
            }
        }
        .listRowBackground(colors.card)
    }

    private func themeRow(_ choice: OpenTalonTheme) -> some View {
        Button {
            theme = choice
        } label: {
            HStack(spacing: 13) {
                themePreview(choice)
                    .accessibilityHidden(true)
                Text(choice.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(colors.text)
                Spacer(minLength: 8)
                if theme == choice {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(colors.actionAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(theme == choice ? .isSelected : [])
        .accessibilityIdentifier("theme.\(choice.rawValue)")
    }

    @ViewBuilder
    private func themePreview(_ choice: OpenTalonTheme) -> some View {
        if choice == .system {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(colors.text)
                .frame(width: 58, height: 35)
                .background(colors.line.opacity(0.45), in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(colors.line) }
        } else {
            let swatch = OpenTalonColors(theme: choice)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(swatch.accent).frame(width: 19, height: 3)
                RoundedRectangle(cornerRadius: 3)
                    .fill(swatch.card)
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(swatch.line) }
            }
            .padding(6)
            .frame(width: 58, height: 35)
            .background(swatch.canvas, in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(swatch.line) }
        }
    }

    private var syncSection: some View {
        Section("iCloud Sync") {
            LabeledContent("Apple Account", value: workspace.accountStatus)
            LabeledContent("Mac workspace", value: workspaceStatus)
            LabeledContent("Last check", value: timestamp(workspace.lastCheck))
            LabeledContent("Last iCloud response", value: timestamp(workspace.lastCloudContact))
            if let snapshot = workspace.snapshot {
                LabeledContent("Mac snapshot", value: timestamp(snapshot.updatedAt))
            }
            if let error = workspace.syncError {
                Text(error).foregroundStyle(.secondary)
            } else if workspace.remoteWorkspaceFound == false {
                Text("iCloud has no workspace from your Mac yet. Open the Mac app and check Settings → iCloud sync.")
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await workspace.sync() }
            } label: {
                if workspace.syncing {
                    ProgressView {
                        Text("Checking iCloud…").foregroundStyle(Color.primary)
                    }
                } else {
                    settingsActionLabel("Check Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(workspace.syncing)
            Toggle("Agent pickup notifications", isOn: Binding(get: { pickupAlerts }, set: { enabled in
                guard enabled else {
                    pickupAlerts = false
                    notificationDenied = false
                    return
                }
                Task {
                    pickupAlerts = (try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert])) == true
                    notificationDenied = !pickupAlerts
                }
            }))
            .tint(colors.actionAccent)
            if notificationDenied {
                Text("Allow notifications for OpenTalon in iOS Settings.")
                    .font(.footnote).foregroundStyle(colors.muted)
            }
        }
        .listRowBackground(colors.card)
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            if let code = workspace.syncErrorCode {
                LabeledContent("Error code", value: code)
                    .textSelection(.enabled)
            }
            ShareLink(item: diagnostics) {
                settingsActionLabel("Share Sync Diagnostics", systemImage: "square.and.arrow.up")
            }
        }
        .listRowBackground(colors.card)
    }

    private var helpSection: some View {
        Section("Support") {
            Button { showTechnicalSupport = true } label: {
                settingsActionLabel("Open a Support Ticket", systemImage: "headphones")
            }
            .accessibilityIdentifier("settingsTechnicalSupport")

            Link(destination: OpenTalonCommunity.websiteHelp) {
                settingsActionLabel("Setup and Troubleshooting", systemImage: "book")
            }
        }
        .listRowBackground(colors.card)
    }

    private var supportSection: some View {
        Section("Support OpenTalon") {
            Button {
                tips.openTipJar()
                showTips = true
            } label: {
                settingsActionLabel("Tip the Developer", systemImage: "cup.and.saucer")
            }
            ShareLink(item: OpenTalonCommunity.website) {
                settingsActionLabel("Share OpenTalon", systemImage: "square.and.arrow.up")
            }
            Link(destination: OpenTalonCommunity.feedback) {
                settingsActionLabel("Send Feedback", systemImage: "bubble.left.and.bubble.right")
            }
            Link(destination: OpenTalonCommunity.protomotaApps) {
                settingsActionLabel("More Free Apps by Protomota", systemImage: "arrow.up.right")
            }
        }
        .listRowBackground(colors.card)
    }

    private func settingsActionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        PhoneActionLabel(title: title, systemImage: systemImage)
    }

    private var aboutSection: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                Image("OpenTalonBrand")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 12))
                    .shadow(color: colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12),
                            radius: 6, y: 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenTalon").font(.headline).foregroundStyle(colors.text)
                    Text("A little room for the things you’re working on.")
                        .font(.subheadline).foregroundStyle(colors.muted)
                }
            }
            .padding(.vertical, 6)
            Text("Version \(appVersion) (\(appBuild))")
                .foregroundStyle(colors.muted)
                .accessibilityIdentifier("settingsAppVersion")
            if tips.isSupporter {
                Label {
                    Text("OpenTalon Supporter")
                } icon: {
                    Image(systemName: "heart.fill").foregroundStyle(colors.actionAccent)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(.tint.opacity(0.55)))
                .accessibilityIdentifier("openTalonSupporterBadge")
            }
            protomotaProductPill
        } header: {
            Text("About").foregroundStyle(colors.muted)
        }
        .listRowBackground(colors.card)
    }

    private var protomotaProductPill: some View {
        Link(destination: OpenTalonCommunity.protomota) {
            HStack(spacing: 8) {
                Image("ProtomotaLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text("A Protomota Product").font(.subheadline.weight(.semibold))
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .frame(minHeight: 44)
            .foregroundStyle(.white)
            .background(.black, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.14)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.protomotaProduct")
    }

    private var productUpdatesSection: some View {
        Section("Product updates") {
            Link(destination: OpenTalonCommunity.newsletter) {
                HStack {
                    settingsActionLabel("Protomota newsletter", systemImage: "envelope")
                    Spacer(minLength: 12)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(colors.actionAccent)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .listRowBackground(colors.card)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var workspaceStatus: String {
        switch workspace.remoteWorkspaceFound {
        case true?: "Found"
        case false?: workspace.snapshot == nil ? "Waiting for Mac" : "Showing saved copy"
        case nil: "Not checked"
        }
    }

    private var diagnostics: String {
        var lines = [
            "OpenTalon \(appVersion) (\(appBuild))",
            "Apple Account: \(workspace.accountStatus)",
            "Mac workspace: \(workspaceStatus)",
            "Last check: \(timestamp(workspace.lastCheck))",
            "Last iCloud response: \(timestamp(workspace.lastCloudContact))",
            "Mac snapshot: \(timestamp(workspace.snapshot?.updatedAt))",
            "Queued changes: \(workspace.pending.count)"
        ]
        if let code = workspace.syncErrorCode { lines.append("Error code: \(code)") }
        return lines.joined(separator: "\n")
    }

    private func timestamp(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "—"
    }
}

@MainActor
@Observable
private final class PhoneTips {
    static let productIDs = ["small", "medium", "large"].map { "com.protomota.opentalon.tip." + $0 }
    private static let purchaseKey = "OpenTalon.supporterTipTransactions"

    struct Celebration: Identifiable {
        let id = UUID()
        let startedAt = Date()
    }

    private var recognizedTips = Set(UserDefaults.standard.stringArray(forKey: purchaseKey) ?? [])
    private(set) var products: [Product] = []
    private(set) var loading = false
    private(set) var purchasingID: String?
    private(set) var message: String?
    private(set) var receivedTip = false
    private(set) var celebration: Celebration?
    var isSupporter: Bool { !recognizedTips.isEmpty }

    func observeTransactions() async {
        for await result in StoreKit.Transaction.unfinished { await receive(result) }
        for await result in StoreKit.Transaction.updates { await receive(result) }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = Self.productIDs.compactMap { id in
                fetched.first { $0.id == id && $0.type == .consumable }
            }
        } catch {
            products = []
        }
    }

    func buy(_ product: Product) async {
        guard purchasingID == nil, products.contains(where: { $0.id == product.id }) else { return }
        purchasingID = product.id
        message = nil
        receivedTip = false
        defer { purchasingID = nil }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result, transaction.productID == product.id {
                    await receive(result)
                } else {
                    message = "The App Store couldn’t verify this tip."
                }
            case .pending:
                message = "Your tip is waiting for App Store approval."
            case .userCancelled:
                break
            @unknown default:
                message = "The App Store couldn’t confirm this tip."
            }
        } catch {
            message = "The App Store couldn’t complete this tip. Please try again."
        }
    }

    private func receive(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result,
              transaction.productType == .consumable,
              transaction.revocationDate == nil,
              Self.productIDs.contains(transaction.productID) else { return }
        if recognizedTips.insert(String(transaction.id)).inserted {
            UserDefaults.standard.set(recognizedTips.sorted(), forKey: Self.purchaseKey)
            receivedTip = true
            message = nil
            celebration = Celebration()
        }
        await transaction.finish()
    }

    func endCelebration(_ id: UUID) {
        if celebration?.id == id { celebration = nil }
    }

    func openTipJar() {
        receivedTip = false
    }
}

private struct TipAmountButtonStyle: ButtonStyle {
    @Environment(\.phoneColors) private var colors
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(colors.text)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.48)
        let shape = Capsule()
        return tipSurface(label, shape: shape)
            .overlay { shape.strokeBorder(colors.tipAmountBorder).allowsHitTesting(false) }
            .contentShape(shape)
    }

    @ViewBuilder
    private func tipSurface(_ label: some View, shape: Capsule) -> some View {
        let fill = colors.card.opacity(0.58)
        if #available(iOS 26.0, *) {
            label.glassEffect(.regular.tint(fill).interactive(enabled), in: shape)
        } else {
            label.background(fill, in: shape)
        }
    }
}

private struct PhoneTipSheet: View {
    @Environment(PhoneTips.self) private var tips
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var accent: Color { colors.actionAccent }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Support OpenTalon", systemImage: "heart")
                    .font(.title2.bold())
                Spacer(minLength: 16)
                Button("Done") { dismiss() }
                    .buttonStyle(PhoneActionButtonStyle())
                    .disabled(tips.purchasingID != nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tips.isSupporter {
                        VStack(spacing: 10) {
                            OpenTalonSupporterEmblem(animationID: tips.celebration?.id)
                            Text("OpenTalon Supporter").font(.subheadline.weight(.semibold))
                            Text(tips.receivedTip ? "Tip completed" : "Thank you for your support")
                                .font(.title3.bold())
                            Text(tips.receivedTip
                                 ? "Thank you for supporting development. You’re all set."
                                 : "Your previous tip was received. You can leave another tip whenever you’d like.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        Text("Leave another tip (optional)").font(.headline)
                    } else {
                        Text("Leave an optional, one-time tip to support development. Every OpenTalon feature is free.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if tips.loading {
                        ProgressView("Loading tips…")
                    } else if tips.products.isEmpty {
                        Text("Tips aren’t available from the App Store right now.")
                        Button("Try Again") { Task { await tips.load() } }
                            .buttonStyle(PhoneActionButtonStyle())
                    }
                    ForEach(tips.products, id: \.id) { product in
                        Button {
                            Task { await tips.buy(product) }
                        } label: {
                            HStack(spacing: 16) {
                                Text(product.displayName).fontWeight(.medium)
                                Spacer(minLength: 0)
                                if tips.purchasingID == product.id {
                                    ProgressView()
                                } else {
                                    Text(product.displayPrice).monospacedDigit().fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TipAmountButtonStyle())
                        .accessibilityIdentifier("tipJarProduct-" + product.id)
                        .disabled(tips.purchasingID != nil)
                    }
                    if let message = tips.message { Text(message).foregroundStyle(.secondary) }
                    Text("Each tip is a separate purchase. Every OpenTalon feature stays free.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://protomota.com/privacy")!) {
                        PhoneActionLabel(title: "Privacy policy", systemImage: "lock.shield")
                    }
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(idealWidth: 440, maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(colors.canvas)
        .tint(accent)
        .overlay {
            if let celebration = tips.celebration, !reduceMotion {
                SupporterConfetti(accent: accent, startedAt: celebration.startedAt)
            }
        }
        .task(id: tips.celebration?.id) {
            guard let celebration = tips.celebration else { return }
            let remaining = max(0, SupporterConfetti.duration - Date().timeIntervalSince(celebration.startedAt))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            tips.endCelebration(celebration.id)
        }
        .interactiveDismissDisabled(tips.purchasingID != nil)
        .task { await tips.load() }
    }
}

private struct PhoneTrashView: View {
    private struct EmptyPreview {
        let workspaceID: UUID
        let revision: Int
        let count: Int
    }

    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @State private var emptyPreview: EmptyPreview?
    @State private var showConfirmation = false
    @State private var error: String?

    private var emptyQueued: Bool {
        workspace.pending.contains {
            guard $0.workspaceID == workspace.snapshot?.workspaceID else { return false }
            if case .emptyTrash = $0.action { return true }
            return false
        }
    }

    var body: some View {
        let tasks = workspace.displayedTrash
        let archiveRemovals = workspace.pendingArchiveRemovals
        List {
            if let tasks {
                if tasks.isEmpty {
                    ContentUnavailableView("Trash is empty", systemImage: "trash")
                } else {
                    Section {
                        Button(role: .destructive) {
                            guard let snapshot = workspace.snapshot else { return }
                            emptyPreview = EmptyPreview(workspaceID: snapshot.workspaceID,
                                                        revision: snapshot.revision, count: tasks.count)
                            showConfirmation = true
                        } label: {
                            Label("Empty Trash", systemImage: "trash")
                        }
                        .disabled(emptyQueued || tasks.contains {
                            workspace.pendingTaskChange(for: $0.id) != nil || archiveRemovals[$0.id] != nil
                        })
                        if emptyQueued {
                            Label("Queued for Mac", systemImage: "clock").foregroundStyle(colors.muted)
                        }
                    }
                    .listRowBackground(colors.card)
                    Section {
                        ForEach(tasks) { task in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title).font(.body.weight(.medium))
                                    Text(workspace.projectName(task.projectID))
                                        .font(.caption).foregroundStyle(colors.muted)
                                }
                                Spacer()
                                Button("Restore") { queue(.restoreTrashed(taskID: task.id, revision: task.revision)) }
                                    .buttonStyle(PhoneActionButtonStyle())
                                    .disabled(emptyQueued || workspace.pendingTaskChange(for: task.id) != nil ||
                                              archiveRemovals[task.id] != nil)
                            }
                        }
                    }
                    .listRowBackground(colors.card)
                }
            } else {
                ContentUnavailableView("Trash needs an update", systemImage: "trash",
                                       description: Text("Update OpenTalon on your Mac and sync to see Trash."))
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(colors.danger)
            }
        }
        .modifier(PhoneListAppearance())
        .navigationTitle("Trash")
        .refreshable { await workspace.sync() }
        .phoneConfirmation("Empty Trash?", isPresented: $showConfirmation,
                           message: emptyTrashMessage, confirm: "Empty Trash", role: .destructive) {
            guard let preview = emptyPreview, preview.workspaceID == workspace.snapshot?.workspaceID else { return }
            queue(.emptyTrash(revision: preview.revision))
        }
    }

    private var emptyTrashMessage: String {
        let count = emptyPreview?.count ?? 0
        let tasks = count == 1 ? "one task" : "\(count) tasks"
        return "This permanently deletes \(tasks). This can’t be undone."
    }

    private func queue(_ action: PhoneRequest.Action) {
        do {
            try workspace.queue(action)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PhoneArchiveView: View {
    private struct BulkPreview {
        let workspaceID: UUID
        let revision: Int
        let ids: [String]
        let permanently: Bool
    }

    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @State private var preview: BulkPreview?
    @State private var showConfirmation = false
    @State private var error: String?
    var projectID: String? = nil

    var body: some View {
        let snapshot = workspace.snapshot
        let permanently = preview?.permanently == true
        let removals = workspace.pendingArchiveRemovals
        let archived = (snapshot?.tasks ?? []).filter {
            $0.archivedAt != nil && (projectID == nil || workspace.displayedProject(for: $0) == projectID)
        }
        let tasks = archived.filter { removals[$0.id] == nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        List {
            if let snapshot, snapshot.supportsBulkArchive, !tasks.isEmpty {
                Section {
                    Button {
                        prepare(tasks, in: snapshot, permanently: false)
                    } label: {
                        PhoneActionLabel(title: "Move All to Trash", systemImage: "trash")
                    }
                    Button("Delete All Permanently…", role: .destructive) {
                        prepare(tasks, in: snapshot, permanently: true)
                    }
                }
                .disabled(tasks.contains { workspace.pendingTaskChange(for: $0.id) != nil } || !removals.isEmpty)
                .listRowBackground(colors.card)
            }
            if archived.contains(where: { removals[$0.id] != nil }) {
                Label("Queued for Mac", systemImage: "clock")
                    .foregroundStyle(colors.muted).listRowBackground(colors.card)
            }
            if tasks.isEmpty {
                ContentUnavailableView("Archive is empty", systemImage: "archivebox")
            } else {
                Section {
                    ForEach(tasks) { TaskLink(task: $0, showProject: projectID == nil, archiveSwipe: true) }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(colors.danger) }
        }
        .modifier(PhoneListAppearance())
        .navigationTitle("Archive")
        .refreshable { await workspace.sync() }
        .phoneConfirmation(permanently ? "Delete all archived tasks?" : "Move all archived tasks to Trash?",
                           isPresented: $showConfirmation, message: archiveConfirmationMessage,
                           confirm: permanently ? "Delete All Permanently" : "Move All to Trash",
                           role: permanently ? .destructive : nil) {
            if let preview { apply(preview) }
        }
    }

    private var archiveConfirmationMessage: String {
        let count = preview?.ids.count ?? 0
        if preview?.permanently == true {
            return "This permanently deletes \(count) archived items. This can’t be undone."
        }
        return "You can restore these \(count) archived items from Trash."
    }

    private func prepare(_ tasks: [PhoneTask], in snapshot: PhoneSnapshot, permanently: Bool) {
        preview = BulkPreview(workspaceID: snapshot.workspaceID, revision: snapshot.revision,
                              ids: tasks.map(\.id), permanently: permanently)
        showConfirmation = true
    }

    private func apply(_ request: BulkPreview) {
        guard request.workspaceID == workspace.snapshot?.workspaceID else { return }
        do {
            try workspace.queue(.manageArchive(taskIDs: request.ids, revision: request.revision,
                                              permanently: request.permanently))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private enum TodayCoordinateSpace: Hashable {
    case list
}

private enum TodayField: Hashable {
    case idea, search
}

private struct TodayView: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @FocusState private var focusedField: TodayField?
    @State private var ideaFrame = CGRect.null
    @State private var searchFrame = CGRect.null
    @State private var search = ""

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = Dictionary(uniqueKeysWithValues: (workspace.snapshot?.projects ?? []).map { ($0.id, $0.name) })
        let active = workspace.orderedTasks((workspace.snapshot?.tasks ?? []).filter {
            $0.archivedAt == nil && workspace.displayedStatus(for: $0) != .done &&
                (query.isEmpty || [$0.title, workspace.hasPendingProjectMove(for: $0) ? "" : $0.displayTaskID ?? "",
                                   projects[workspace.displayedProject(for: $0)] ?? "", $0.notes]
                    .contains { $0.localizedStandardContains(query) })
        }, byPriority: true)
        let urgent = active.filter { workspace.displayedPriority(for: $0) == .urgent }
        let other = active.filter { workspace.displayedPriority(for: $0) != .urgent }
        List {
            if let snapshot = workspace.snapshot, !snapshot.projects.isEmpty {
                TodayCapture(projects: snapshot.projects, workspaceID: snapshot.workspaceID,
                             ideaFrame: $ideaFrame, focusedField: $focusedField)
                    .id(snapshot.workspaceID)
            }
            if let updated = workspace.snapshot?.updatedAt {
                Text("Mac snapshot \(updated.formatted(.relative(presentation: .named)))")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(colors.card)
            }
            searchRow
            if let notice = workspace.pickupNotice {
                PhonePickupNotice(message: notice).listRowBackground(colors.card)
            }
            if let error = workspace.syncError {
                Text(error).font(.footnote).foregroundStyle(.secondary).listRowBackground(colors.card)
            }
            if active.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("You’re caught up", systemImage: "checkmark.circle",
                                           description: Text("Open tasks appear here."))
                } else {
                    ContentUnavailableView("No matching tasks", systemImage: "magnifyingglass")
                }
            }
            if !urgent.isEmpty {
                Section {
                    ForEach(urgent) { TaskLink(task: $0, showProject: true, showStatus: true) }
                } header: {
                    Label("Urgent tasks", systemImage: "flag.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.danger)
                }
            }
            if !other.isEmpty {
                Section("Other tasks") {
                    ForEach(other) { TaskLink(task: $0, showProject: true, showStatus: true) }
                }
            }
            Section {
                NavigationLink {
                    PhoneArchiveView()
                } label: {
                    PhoneActionLabel(title: "Archive", systemImage: "archivebox")
                }
                NavigationLink {
                    PhoneTrashView()
                } label: {
                    PhoneActionLabel(title: "Trash", systemImage: "trash")
                }
            }
            .listRowBackground(colors.card)
        }
        .modifier(PhoneListAppearance())
        .refreshable { await workspace.sync() }
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .coordinateSpace(name: TodayCoordinateSpace.list)
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named(TodayCoordinateSpace.list)).onEnded { tap in
                if !ideaFrame.contains(tap.location), !searchFrame.contains(tap.location) { focusedField = nil }
            },
            including: focusedField == nil ? .none : .all
        )
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(colors.actionAccent)
                .accessibilityHidden(true)
            TextField("Search tasks", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .search)
                .submitLabel(.search)
                .onSubmit { focusedField = nil }
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(colors.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(TodayCoordinateSpace.list))
        } action: { searchFrame = $0 }
        .listRowBackground(colors.card)
    }
}

private struct TodayCapture: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @State private var idea = ""
    @State private var priority: PhoneTask.Priority?
    @State private var selectedProject: String?
    @State private var saving = false
    @State private var feedback: String?
    @State private var failed = false

    let projects: [PhoneProject]
    let workspaceID: UUID
    @Binding var ideaFrame: CGRect
    @FocusState.Binding var focusedField: TodayField?

    private var input: String { idea.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { input.utf16.count > SuggestedTaskDetails.captureLimit }
    private var project: String {
        let fallback = selectedProject ?? workspace.snapshot?.captureProjectID
        return projects.first { $0.id == fallback }?.id ?? projects.first?.id ?? ""
    }

    var body: some View {
        Section {
            TextField("Type or dictate a to-do", text: $idea, axis: .vertical)
                .lineLimit(2...5)
                .focused($focusedField, equals: .idea)
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(TodayCoordinateSpace.list))
                } action: { ideaFrame = $0 }
                .accessibilityLabel("To-do idea")
                .disabled(saving)
            Picker("Project", selection: $selectedProject) {
                Text("Auto").tag(nil as String?)
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(saving)
            Picker("Priority", selection: $priority) {
                Text("Auto").tag(nil as PhoneTask.Priority?)
                ForEach(PhoneTask.Priority.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .disabled(saving)
            Button(action: add) {
                if saving {
                    ProgressView("Drafting on this device…")
                } else {
                    PhoneActionLabel(title: "Add to-do", systemImage: "plus")
                }
            }
            .buttonStyle(PhoneActionButtonStyle())
            .disabled(input.isEmpty || tooLong || project.isEmpty || saving)
        } header: {
            Text("Quick add")
        } footer: {
            if tooLong {
                Text("Keep your idea to 2,000 characters.").foregroundStyle(colors.danger)
            } else if let feedback {
                Text(feedback).foregroundStyle(failed ? colors.danger : colors.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .listRowBackground(colors.card)
    }

    private func add() {
        guard !input.isEmpty, !tooLong, !project.isEmpty, !saving else { return }
        let idea = input
        let project = project
        let autoProject = selectedProject == nil
        let priority = priority
        focusedField = nil
        saving = true
        failed = false
        feedback = nil
        Task {
            defer { saving = false }
            let suggestion = try? await TaskDrafting.expand(idea, projects: autoProject ? projects : nil)
            let generated = suggestion.flatMap { $0.isUsableForCapture ? $0 : nil }
            let draft = generated ?? .fromIdea(idea)
            guard let snapshot = workspace.snapshot, snapshot.workspaceID == workspaceID else { return }
            let destination = autoProject
                ? TaskDrafting.captureDestination(in: idea, projects: snapshot.projects, suggestedName: suggestion?.projectName)
                : (projectID: nil, newProjectName: nil)
            let resolvedPriority = priority ?? TaskDrafting.capturePriority(in: idea)
            if destination.newProjectName != nil, snapshot.captureProjectID == nil {
                failed = true
                feedback = "Update OpenTalon on your Mac to create a new project from Quick Add."
                return
            }
            do {
                try workspace.queue(.create(
                    projectID: destination.projectID ?? project, title: draft.title, notes: draft.notes,
                    priority: resolvedPriority, sendToAgent: false, definitionOfDone: generated?.definitionOfDone,
                    newProjectName: destination.newProjectName
                ))
                self.idea = ""
                self.priority = nil
                self.selectedProject = nil
                let destinationName = destination.newProjectName
                    ?? workspace.projectName(destination.projectID ?? project)
                feedback = generated == nil
                    ? "Queued for \(destinationName) · \(resolvedPriority.title). Apple Intelligence drafting was unavailable."
                    : "Queued for \(destinationName) · \(resolvedPriority.title)."
            } catch {
                failed = true
                feedback = error.localizedDescription
            }
        }
    }
}

private struct ProjectsView: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @SceneStorage("projects.sidebarVisible") private var sidebarVisible = true
    @SceneStorage("projects.selection") private var selectedProjectID: String?

    var body: some View {
        let projects = workspace.snapshot?.projects ?? []
        GeometryReader { geometry in
            if geometry.size.width >= 640, geometry.size.width > geometry.size.height,
               !dynamicTypeSize.isAccessibilitySize, let firstProject = projects.first {
                let selection = projects.first { $0.id == selectedProjectID } ?? firstProject
                wideProjects(projects, selection: selection, showsSidebarControl: geometry.size.width >= 1000)
            } else {
                projectList(projects)
            }
        }
        .background(colors.canvas.ignoresSafeArea())
    }

    private func projectList(_ projects: [PhoneProject]) -> some View {
        List(projects) { project in
            NavigationLink {
                ProjectTasks(project: project)
                    .navigationTitle(project.name)
            } label: {
                LabeledContent(project.name, value: "\(openCount(for: project)) open")
            }
            .listRowBackground(colors.card)
        }
        .modifier(PhoneListAppearance())
        .refreshable { await workspace.sync() }
    }

    private func wideProjects(_ projects: [PhoneProject], selection: PhoneProject, showsSidebarControl: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if showsSidebarControl {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
                    } label: {
                        PhoneActionLabel(title: sidebarVisible ? "Hide Projects" : "Show Projects", systemImage: "sidebar.left")
                    }
                    .buttonStyle(PhoneActionButtonStyle())
                    .accessibilityIdentifier("projectsSidebarToggle")
                    Text(selection.name).font(.title2.bold())
                        .foregroundStyle(colors.text)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Menu {
                        Picker("Project", selection: Binding(
                            get: { selection.id }, set: { selectedProjectID = $0 }
                        )) {
                            ForEach(projects) { project in
                                Text(project.name).tag(project.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            PhoneActionLabel(title: LocalizedStringKey(selection.name), systemImage: "folder")
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                                .foregroundStyle(colors.muted)
                        }
                    }
                    .buttonStyle(PhoneActionButtonStyle())
                    .accessibilityLabel("Project")
                    .accessibilityValue(selection.name)
                    .accessibilityIdentifier("boardProjectPicker")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            HStack(spacing: 0) {
                if showsSidebarControl && sidebarVisible {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(projects) { project in
                                let selected = project.id == selection.id
                                Button {
                                    selectedProjectID = project.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(selected ? colors.actionAccent : colors.muted)
                                            .accessibilityHidden(true)
                                        Text(project.name).lineLimit(2)
                                        Spacer(minLength: 4)
                                        Text(openCount(for: project), format: .number)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(colors.muted)
                                            .accessibilityLabel("\(openCount(for: project)) open")
                                    }
                                    .font(.callout.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(colors.text)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .background(selected ? colors.actionAccent.opacity(0.10) : .clear, in: .rect(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 225)
                    .background(colors.card, in: .rect(cornerRadius: 16))
                    .padding(.leading, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .accessibilityIdentifier("projectsSidebar")
                }
                ProjectTasks(project: selection)
                    .id(selection.id)
            }
        }
    }

    private func openCount(for project: PhoneProject) -> Int {
        workspace.snapshot?.tasks.filter {
            workspace.displayedProject(for: $0) == project.id && workspace.displayedStatus(for: $0) != .done
        }.count ?? 0
    }
}

private struct ProjectTasks: View {
    private enum Sort: String, CaseIterable {
        case defaultOrder, urgency

        var title: String { self == .defaultOrder ? "My order" : "Urgency" }
    }

    @Environment(PhoneWorkspace.self) private var workspace
    let project: PhoneProject

    @Environment(\.phoneColors) private var colors
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("projects.taskSort") private var sort = Sort.defaultOrder
    @State private var editMode: EditMode = .inactive
    @State private var highlightedLane: PhoneTask.Status?
    @State private var highlightedTaskID: String?
    @State private var taskToSend: BoardTaskDrag?
    @State private var moveError: String?
    @State private var showSort = false

    private let statuses: [PhoneTask.Status] = [.todo, .sent, .working, .done]

    private var canReorder: Bool {
        sort == .defaultOrder && workspace.snapshot?.supportsTaskReordering == true
    }

    var body: some View {
        let snapshot = workspace.snapshot
        let projectTasks = (snapshot?.tasks ?? []).filter { workspace.displayedProject(for: $0) == project.id }
        let tasks = projectTasks.filter { $0.archivedAt == nil }
        let archived = projectTasks.filter { $0.archivedAt != nil }
        GeometryReader { geometry in
            if geometry.size.width >= 640 && !dynamicTypeSize.isAccessibilitySize, let snapshot {
                board(snapshot: snapshot, tasks: tasks, archived: archived, width: geometry.size.width)
            } else {
                List {
                    Section {
                        HStack {
                            Spacer()
                            if canReorder {
                                Button(editMode.isEditing ? "Done" : "Reorder") {
                                    withAnimation(reduceMotion ? nil : .default) {
                                        editMode = editMode.isEditing ? .inactive : .active
                                    }
                                }
                                .buttonStyle(PhoneActionButtonStyle())
                            }
                            sortMenu
                        }
                        .listRowBackground(colors.canvas)
                        .listRowInsets(EdgeInsets())
                    }
                    ForEach(statuses, id: \.self) { status in
                        let items = items(for: status, in: tasks)
                        if !items.isEmpty {
                            Section(status.rawValue) {
                                ForEach(items) { TaskLink(task: $0, showProject: false) }
                                    .onMove { indices, destination in
                                        reorderTasks(items, from: indices, to: destination, status: status)
                                    }
                                    .moveDisabled(!canReorder)
                            }
                        }
                    }
                    if !archived.isEmpty {
                        Section { archiveLink }
                            .listRowBackground(colors.card)
                    }
                    if let moveError {
                        Text(moveError).font(.footnote).foregroundStyle(colors.danger)
                    }
                }
                .environment(\.editMode, $editMode)
                .overlay {
                    if projectTasks.isEmpty { ContentUnavailableView("No tasks", systemImage: "checklist") }
                }
            }
        }
        .modifier(PhoneListAppearance())
        .onChange(of: canReorder) {
            if !canReorder { editMode = .inactive }
        }
        .refreshable { await workspace.sync() }
        .sheet(item: $taskToSend) { payload in
            if let snapshot, snapshot.workspaceID == payload.workspaceID,
               let task = snapshot.tasks.first(where: { $0.id == payload.taskID }) {
                PhoneAgentChooser(snapshot: snapshot, taskTitle: task.title) { agent, model, comment in
                    try workspace.queueField(.status(.sent, agent: agent, model: model, dispatchComment: comment),
                                             for: task, in: snapshot.workspaceID)
                }
            }
        }
    }

    private var archiveLink: some View {
        NavigationLink {
            PhoneArchiveView(projectID: project.id)
        } label: {
            PhoneActionLabel(title: "Archive", systemImage: "archivebox")
        }
    }

    private var sortMenu: some View {
        Button {
            showSort = true
        } label: {
            PhoneActionLabel(title: sort == .urgency ? "Urgency" : "My order", systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(PhoneActionButtonStyle())
        .accessibilityLabel("Sort tasks")
        .accessibilityValue(sort.title)
        .accessibilityIdentifier("projectSort")
        .popover(isPresented: $showSort, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Sort.allCases, id: \.self) { option in
                    Button {
                        sort = option
                        showSort = false
                    } label: {
                        HStack {
                            Text(option.title)
                                .foregroundStyle(colors.text)
                            Spacer(minLength: 12)
                            if sort == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(colors.actionAccent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sort == option ? .isSelected : [])
                }
            }
            .frame(minWidth: 160)
            .padding(6)
            .presentationCompactAdaptation(.popover)
            .presentationBackground(colors.card)
        }
    }

    private func board(snapshot: PhoneSnapshot, tasks: [PhoneTask], archived: [PhoneTask], width: CGFloat) -> some View {
        let laneWidth = max(140, (width - 72) / 4)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if snapshot.supportsFieldEditing {
                    PhoneActionLabel(title: canReorder ? "Touch and hold a card to reorder it or move it to another column."
                                     : "Touch and hold a card to move it to another column.", systemImage: "hand.draw")
                        .font(.caption)
                }
                Spacer()
                sortMenu
                if !archived.isEmpty { archiveLink.buttonStyle(PhoneActionButtonStyle()) }
            }
            .padding(.horizontal, 18)
            if let moveError {
                Text(moveError).font(.caption).foregroundStyle(colors.danger)
                    .padding(.horizontal, 18)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(statuses, id: \.self) { status in
                        statusColumn(status, tasks: tasks, in: snapshot)
                            .frame(width: laneWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.top, 8)
    }

    private func items(for status: PhoneTask.Status, in tasks: [PhoneTask]) -> [PhoneTask] {
        let matching = tasks.filter { workspace.displayedStatus(for: $0) == status }
        if sort == .urgency { return workspace.orderedTasks(matching, byPriority: true) }
        if canReorder { return workspace.manualTaskOrder(matching, projectID: project.id, status: status) }
        return status == .todo ? workspace.orderedTasks(matching) : matching
    }

    private func reorderTasks(_ items: [PhoneTask], from indices: IndexSet, to destination: Int,
                              status: PhoneTask.Status) {
        guard canReorder, items.count > 1, indices.count == 1, let index = indices.first else { return }
        let task = items[index]
        var reordered = items
        reordered.move(fromOffsets: indices, toOffset: destination)
        guard let position = reordered.firstIndex(where: { $0.id == task.id }), position != index else { return }
        let anchor = reordered[position == 0 ? 1 : position - 1]
        queueReorder(task.id, status: status, anchorID: anchor.id, before: position == 0)
    }

    private func queueReorder(_ id: String, status: PhoneTask.Status, anchorID: String, before: Bool) {
        guard canReorder, id != anchorID else { return }
        do {
            moveError = nil
            try withAnimation(reduceMotion ? nil : .snappy(duration: 0.30)) {
                try workspace.queue(.reorderTask(taskID: id, projectID: project.id, status: status,
                                                 anchorID: anchorID, before: before))
            }
        } catch {
            moveError = error.localizedDescription
        }
    }

    private func statusColumn(_ status: PhoneTask.Status, tasks: [PhoneTask], in snapshot: PhoneSnapshot) -> some View {
        let items = items(for: status, in: tasks)
        let targeted = highlightedLane == status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(status.rawValue).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(items.count, format: .number).font(.caption.monospacedDigit())
                    .foregroundStyle(colors.muted)
            }
            .padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { task in
                        let card = VStack(alignment: .leading, spacing: 6) {
                            TaskLink(task: task, showProject: false)
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("boardCard-\(task.id)")
                            if workspace.displayedStatus(for: task) != task.status {
                                Label("Queued for Mac", systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(colors.muted)
                            }
                        }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(colors.card, in: .rect(cornerRadius: 12))
                            .overlay {
                                if highlightedTaskID == task.id {
                                    RoundedRectangle(cornerRadius: 12).strokeBorder(colors.actionAccent)
                                        .allowsHitTesting(false)
                                }
                            }
                        if snapshot.supportsFieldEditing,
                           snapshot.supportsTaskOverrides || workspace.pendingTaskChange(for: task.id) == nil {
                            let draggableCard = card.draggable(BoardTaskDrag(workspaceID: snapshot.workspaceID, taskID: task.id))
                            if canReorder {
                                draggableCard
                                    .onDrop(of: [BoardTaskDrag.contentType], isTargeted: Binding(
                                        get: { highlightedTaskID == task.id },
                                        set: { targeted in
                                            if targeted { highlightedTaskID = task.id }
                                            else if highlightedTaskID == task.id { highlightedTaskID = nil }
                                        }
                                    )) { providers in
                                        handleDrop(providers, to: status, anchorID: task.id)
                                    }
                                    .accessibilityHint("Touch and hold to reorder or move to another column")
                            } else {
                                draggableCard.accessibilityHint("Touch and hold to move to another column")
                            }
                        } else {
                            card
                        }
                    }
                    if items.isEmpty, snapshot.supportsFieldEditing {
                        Text("Drop a task here").font(.caption)
                            .foregroundStyle(targeted ? colors.actionAccent : colors.muted)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(targeted ? colors.actionAccent.opacity(0.13) : colors.line.opacity(0.24), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(targeted ? colors.actionAccent : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityIdentifier("boardLane-\(status.rawValue)")
        .onDrop(of: [BoardTaskDrag.contentType], isTargeted: Binding(
            get: { highlightedLane == status },
            set: { active in
                if active { highlightedLane = status }
                else if highlightedLane == status { highlightedLane = nil }
            }
        )) { providers in
            guard snapshot.supportsFieldEditing else { return false }
            return handleDrop(providers, to: status)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], to status: PhoneTask.Status,
                            anchorID: String? = nil) -> Bool {
        guard let provider = providers.first else { return false }
        // Update the board after the system drop callback returns.
        _ = provider.loadTransferable(type: BoardTaskDrag.self) { result in
            Task { @MainActor in
                switch result {
                case .success(let payload): move(payload, to: status, anchorID: anchorID)
                case .failure: moveError = "Couldn’t read the dropped task. Try again."
                }
            }
        }
        return true
    }

    private func move(_ payload: BoardTaskDrag, to status: PhoneTask.Status, anchorID: String?) {
        guard let snapshot = workspace.snapshot, snapshot.workspaceID == payload.workspaceID,
              snapshot.supportsFieldEditing,
              let task = snapshot.tasks.first(where: {
                  $0.id == payload.taskID && $0.archivedAt == nil && workspace.displayedProject(for: $0) == project.id
              }) else { return }
        if workspace.displayedStatus(for: task) == status {
            guard canReorder else { return }
            let column = items(for: status, in: snapshot.tasks.filter {
                $0.archivedAt == nil && workspace.displayedProject(for: $0) == project.id
            })
            if let targetID = anchorID ?? column.last?.id,
               let source = column.firstIndex(where: { $0.id == task.id }),
               let target = column.firstIndex(where: { $0.id == targetID }) {
                queueReorder(task.id, status: status, anchorID: targetID, before: source > target)
            }
            return
        }
        guard snapshot.supportsTaskOverrides || workspace.pendingTaskChange(for: task.id) == nil else {
            moveError = "Wait for the current task change to sync with your Mac."
            return
        }
        guard status != .done || !task.assigned else {
            moveError = "This task is assigned to an agent."
            return
        }
        moveError = nil
        if status == .sent {
            taskToSend = payload
            return
        }
        do {
            try withAnimation(reduceMotion ? nil : .snappy(duration: 0.30)) {
                try workspace.queueField(.status(status), for: task, in: snapshot.workspaceID)
            }
        } catch {
            moveError = error.localizedDescription
        }
    }

}

private struct PhoneAgentLabel: View {
    @Environment(\.phoneColors) private var colors
    @Environment(\.colorScheme) private var colorScheme
    let agent: PhoneAgent
    let title: String

    var body: some View {
        Label {
            Text(title).foregroundStyle(colors.text)
        } icon: {
            OpenTalonAgentMark(
                image: Image(agent == .claude ? "ClaudeMark" : "OpenAIMark"),
                isClaude: agent == .claude,
                darkSurface: colorScheme == .dark,
                size: 16
            )
        }
    }
}

private struct PhoneAgentChooser: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneColors) private var colors
    @State private var selectedAgent: PhoneAgent?
    @State private var selectedModel: String?
    @State private var comment = ""
    @State private var error: String?
    let snapshot: PhoneSnapshot
    let taskTitle: String
    let choose: (PhoneAgent, String?, String?) throws -> Void

    private var agents: [PhoneAgent] {
        let preferred = snapshot.defaultAgent ?? .codex
        let available = snapshot.availableAgents ?? [preferred]
        guard available.contains(preferred) else { return available }
        return [preferred] + available.filter { $0 != preferred }
    }

    private var agent: PhoneAgent? {
        selectedAgent.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first
    }

    private var models: [AgentModelChoice] {
        (snapshot.agentModels ?? []).filter { $0.agent == agent }
    }

    private var commentText: String {
        comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                Text("Send to agent")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                Button("Send", action: send)
                    .disabled(agent == nil || commentText.utf16.count > 10_000)
                    .accessibilityIdentifier("confirmAgentSend")
            }
            .buttonStyle(PhoneActionButtonStyle())
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Form {
                Section {
                    Text(taskTitle)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Your Mac will start the task after it syncs.")
                }
                .listRowBackground(colors.card)

                Section("Agent") {
                    ForEach(agents) { option in
                        Button {
                            selectedAgent = option
                        } label: {
                            HStack {
                                PhoneAgentLabel(agent: option, title: option.title)
                                if option == agents.first {
                                    Text("Default")
                                        .font(.caption)
                                        .foregroundStyle(colors.muted)
                                }
                                Spacer()
                                if option == agent {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(colors.actionAccent)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == agent ? .isSelected : [])
                        .accessibilityIdentifier("sendAgent-\(option.rawValue)")
                    }
                    if agents.isEmpty {
                        Text("Set up Codex or Claude on your Mac to send this task.")
                            .foregroundStyle(colors.muted)
                    }
                }
                .listRowBackground(colors.card)

                Section {
                    Picker("Model", selection: $selectedModel) {
                        Text("Agent default").tag(nil as String?)
                        ForEach(models) { model in
                            Text(model.title).tag(Optional(model.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(colors.text)
                    .accessibilityIdentifier("sendModelPicker")
                }
                .listRowBackground(colors.card)

                Section("Comment (optional)") {
                    if snapshot.supportsDispatchComments {
                        TextField("Add context or instructions for the agent", text: $comment, axis: .vertical)
                            .lineLimit(4...8)
                            .accessibilityIdentifier("sendComment")
                        if commentText.utf16.count > 10_000 {
                            Text("Comments can be up to 10,000 characters.")
                                .font(.caption)
                                .foregroundStyle(colors.danger)
                        }
                    } else {
                        Text("Update OpenTalon on your Mac to include a comment when you send.")
                            .foregroundStyle(colors.muted)
                    }
                }
                .listRowBackground(colors.card)
                if let error {
                    Text(error).foregroundStyle(colors.danger).listRowBackground(colors.card)
                }
            }
            .foregroundStyle(colors.text)
            .modifier(PhoneListAppearance())
            .onChange(of: agent) { selectedModel = nil }
            .onChange(of: models) {
                if !models.contains(where: { $0.id == selectedModel }) { selectedModel = nil }
            }
        }
        .background(colors.canvas)
        .presentationDetents([.large])
    }

    private func send() {
        guard let agent, commentText.utf16.count <= 10_000 else { return }
        let model = models.first(where: { $0.id == selectedModel })?.id
        do {
            try choose(agent, model, snapshot.supportsDispatchComments && !commentText.isEmpty ? commentText : nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BoardTaskDrag: Codable, Identifiable, Transferable {
    static let contentType = UTType(exportedAs: "com.protomota.opentalon.board-task")
    let workspaceID: UUID
    let taskID: String
    var id: String { taskID }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

private struct TaskLink: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @Environment(\.colorScheme) private var scheme
    @State private var completionError: String?
    @State private var confirmCompletion = false
    let task: PhoneTask
    let showProject: Bool
    var showStatus = false
    var archiveSwipe = false

    var body: some View {
        NavigationLink {
            TaskView(taskID: task.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title).font(.body.weight(.semibold))
                if workspace.hasPendingProjectMove(for: task) {
                    Text("New task ID syncing…").font(.caption).foregroundStyle(colors.muted)
                } else if let taskKey = task.displayTaskID {
                    Text(taskKey).font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(colors.text)
                        .accessibilityLabel("Task ID \(taskKey)")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metadata }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(colors.text)
                if showStatus {
                    let status = workspace.displayedStatus(for: task)
                    Label(status.mobileStage, systemImage: status.mobileStageIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(colors.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(colors.actionAccent.opacity(0.10), in: Capsule())
                        .accessibilityIdentifier("taskStage-\(task.id)")
                }
                if let date = task.createdAt {
                    Text("Created \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline).foregroundStyle(colors.muted)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .listRowBackground(colors.card)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !archiveSwipe, workspace.canMarkDone(task) {
                Button {
                    if workspace.completionNeedsConfirmation(for: task) { confirmCompletion = true }
                    else { markDone() }
                } label: {
                    Label("Mark done", systemImage: "checkmark")
                }
                .tint(colors.actionAccent)
            } else if archiveSwipe, workspace.snapshot?.trashedTasks != nil,
                      workspace.pendingTaskChange(for: task.id) == nil {
                Button(role: .destructive) {
                    do { try workspace.queue(.removeArchived(taskID: task.id, revision: task.revision, permanently: false)) }
                    catch { completionError = error.localizedDescription }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
            }
        }
        .phoneConfirmation(archiveSwipe ? "Couldn’t move task to Trash" : "Couldn’t mark task done", isPresented: Binding(
            get: { completionError != nil },
            set: { if !$0 { completionError = nil } }
        ), message: completionError ?? "", confirm: "OK", cancel: nil, action: {})
        .phoneConfirmation("Mark this task done anyway?", isPresented: $confirmCompletion,
                           message: "This stops any active agent run and moves the task to Done.",
                           confirm: "Mark Done", action: markDone)
    }

    private func markDone() {
        do { try workspace.markDone(task) }
        catch { completionError = error.localizedDescription }
    }

    @ViewBuilder private var metadata: some View {
        if showProject { Text(workspace.projectName(workspace.displayedProject(for: task))) }
        let priority = workspace.displayedPriority(for: task)
        if priority != .none {
            let tint = priorityTint(priority)
            Text(priority.title)
                .font(.subheadline.weight(priority == .urgent ? .bold : .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(tint)
                .background(tint.opacity(0.11), in: Capsule())
        }
        if let due = task.dueDate { Text("Due \(CalendarDay.label(due))") }
    }

    private func priorityTint(_ priority: PhoneTask.Priority) -> Color {
        switch priority {
        case .urgent: colors.danger
        case .high: scheme == .dark ? Color(red: 1, green: 0.72, blue: 0.44)
            : Color(red: 0.57, green: 0.28, blue: 0.04)
        case .medium: scheme == .dark ? Color(red: 0.92, green: 0.81, blue: 0.45)
            : Color(red: 0.43, green: 0.34, blue: 0.03)
        case .low: OpenTalonColors(theme: .system, systemScheme: scheme).actionAccent
        case .none: colors.muted
        }
    }
}

private extension PhoneTask.Status {
    var mobileStage: String {
        self == .sent ? "Sending to agent" : rawValue
    }

    var mobileStageIcon: String {
        switch self {
        case .todo: "circle"
        case .sent: "paperplane"
        case .working: "play.circle"
        case .done: "checkmark"
        }
    }
}

private struct PhonePickupNotice: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.icloud").foregroundStyle(colors.actionAccent).accessibilityHidden(true)
            Text(message).font(.callout.weight(.medium))
                .accessibilityAddTraits(.updatesFrequently)
            Spacer()
            Button { workspace.dismissPickupNotice() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(colors.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss pickup notice")
        }
    }
}

private func pickupCaption(macName: String?, date: Date) -> String {
    "Picked up by \(macName ?? "your Mac") · \(date.formatted(date: .abbreviated, time: .shortened))"
}

private struct NotesEdit: Identifiable {
    let task: PhoneTask
    let workspaceID: UUID
    let unsaved: PhoneWorkspace.UnsavedNotes?
    var id: String { task.id }
}

private struct DueDateEdit: Identifiable {
    let task: PhoneTask
    let workspaceID: UUID
    let currentDueDate: String?
    var id: String { task.id }
}

private struct TaskView: View {
    @State private var confirmArchiveDeletion = false
    @State private var confirmForceComplete = false
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @Environment(\.scenePhase) private var phase
    @State private var showSend = false
    @State private var notesEdit: NotesEdit?
    @State private var dueDateEdit: DueDateEdit?
    @State private var showComment = false
    @State private var keepCommentDraftOnCancel = false
    @State private var comment = ""
    @State private var commentWorkspaceID: UUID?
    @State private var commentSaved = false
    @State private var commentError: String?
    @State private var copiedTaskReference: String?
    @State private var error: String?
    let taskID: String

    private var commentText: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var commentTooLong: Bool { commentText.utf16.count > 10_000 }

    var body: some View {
        if let snapshot = workspace.snapshot,
           let task = snapshot.tasks.first(where: { $0.id == taskID }) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        if workspace.hasPendingProjectMove(for: task) {
                            Text("New task ID syncing…").font(.caption).foregroundStyle(colors.muted)
                        } else if let reference = task.displayTaskID {
                            taskReferenceHeader(reference)
                        } else {
                            Text("Task ID will appear after syncing with your Mac.")
                                .font(.caption)
                                .foregroundStyle(colors.muted)
                        }
                        Text(task.title).font(.title2.weight(.semibold))
                        quickActions(for: task, in: snapshot)
                        if let pickup = task.agentPickup {
                            Label(pickupCaption(macName: snapshot.macName, date: pickup.at), systemImage: "checkmark.icloud")
                                .font(.caption).foregroundStyle(colors.muted)
                        }
                        if let dispatchError = task.agentDispatchError, workspace.displayedStatus(for: task) == .todo {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Agent didn’t start", systemImage: "exclamationmark.circle")
                                    .foregroundStyle(colors.danger)
                                Text(dispatchError).foregroundStyle(colors.muted)
                            }
                            .font(.caption)
                        }
                        if let error {
                            Text(error).font(.caption).foregroundStyle(colors.danger)
                        }
                    }
                    properties(for: task, in: snapshot)
                }
                .listRowBackground(colors.card)
                notes(for: task, in: snapshot)
                if !task.definitionOfDone.isEmpty {
                    Section("Definition of done") { Text(task.definitionOfDone).textSelection(.enabled) }
                        .listRowBackground(colors.card)
                }
                comments(for: task)
                if task.archivedAt != nil, snapshot.trashedTasks != nil {
                    Section {
                        Button(role: .destructive) {
                            queue(.removeArchived(taskID: task.id, revision: task.revision, permanently: false))
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                        Button("Delete Permanently…", role: .destructive) { confirmArchiveDeletion = true }
                    }
                    .disabled(workspace.pendingTaskChange(for: task.id) != nil)
                    .listRowBackground(colors.card)
                }
            }
            .modifier(PhoneListAppearance())
            .onChange(of: snapshot.workspaceID, initial: true) {
                commentWorkspaceID = snapshot.workspaceID
                comment = workspace.commentDraft(for: taskID, in: snapshot.workspaceID)
                commentSaved = false
                commentError = nil
            }
            .onChange(of: phase) {
                if phase != .active { saveCommentDraft() }
            }
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .phoneConfirmation("Delete this task permanently?", isPresented: $confirmArchiveDeletion,
                               message: "“\(task.title)” and its comments will be permanently deleted. This can’t be undone.",
                               confirm: "Delete Permanently", role: .destructive) {
                guard workspace.snapshot?.workspaceID == snapshot.workspaceID else { return }
                queue(.removeArchived(taskID: task.id, revision: task.revision, permanently: true))
            }
            .phoneConfirmation("Mark this task done anyway?", isPresented: $confirmForceComplete,
                               message: "This stops any active agent run and moves the task to Done.",
                               confirm: "Mark Done") {
                guard workspace.snapshot?.workspaceID == snapshot.workspaceID else { return }
                markDone(task)
            }
            .sheet(item: $notesEdit) { edit in
                NotesEditor(edit: edit)
            }
            .sheet(item: $dueDateEdit) { edit in
                DueDateEditor(edit: edit)
            }
            .sheet(isPresented: $showComment, onDismiss: finishComment) {
                commentEditor
            }
            .sheet(isPresented: $showSend) {
                PhoneAgentChooser(snapshot: snapshot, taskTitle: task.title) { agent, model, comment in
                    if snapshot.supportsFieldEditing {
                        try workspace.queueField(.status(.sent, agent: agent, model: model, dispatchComment: comment),
                                                 for: task, in: snapshot.workspaceID)
                    } else {
                        try workspace.queue(.send(taskID: task.id, revision: task.revision, agent: agent))
                    }
                }
            }
        } else {
            ContentUnavailableView("Task unavailable", systemImage: "checklist")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colors.canvas.ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func quickActions(for task: PhoneTask, in snapshot: PhoneSnapshot) -> some View {
        let status = workspace.displayedStatus(for: task)
        let canChangeStatus = snapshot.supportsFieldEditing
            && (snapshot.supportsTaskOverrides || workspace.pendingTaskChange(for: task.id) == nil)
        let returningToTodo = status == .sent || status == .working
        if task.archivedAt != nil || status == .done {
            if canChangeStatus, status == .done {
                returnToTodoButton(for: task, in: snapshot, reopening: true)
                    .buttonStyle(PhoneActionButtonStyle())
                    .padding(.top, 8)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    taskActionButtons(for: task, in: snapshot, returningToTodo: returningToTodo,
                                      canChangeStatus: canChangeStatus)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 6) {
                    taskActionButtons(for: task, in: snapshot, returningToTodo: returningToTodo,
                                      canChangeStatus: canChangeStatus)
                }
            }
            .buttonStyle(PhoneActionButtonStyle(horizontalPadding: 9))
            .padding(.top, 8)

            if status == .todo, canChangeStatus {
                Button {
                    queueField(.status(.working), for: task, in: snapshot)
                } label: {
                    quickActionLabel("In progress", systemImage: "play.circle")
                }
                .buttonStyle(PhoneActionButtonStyle(horizontalPadding: 9))
                .accessibilityLabel("Mark in progress")
                .accessibilityIdentifier("taskQuickInProgress")
            } else if status == .working, workspace.canMarkDone(task), !task.assigned {
                sendToAgentButton
                    .buttonStyle(PhoneActionButtonStyle(horizontalPadding: 9))
            }
        }
        if let pending = workspace.pendingTaskChange(for: task.id) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Queued for Mac", systemImage: "clock")
                    .font(.callout)
                if let message = workspace.waitingMessage(for: pending) {
                    Text(message).font(.caption)
                }
            }
            .foregroundStyle(colors.muted)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func taskActionButtons(for task: PhoneTask, in snapshot: PhoneSnapshot,
                                   returningToTodo: Bool, canChangeStatus: Bool) -> some View {
        if workspace.canMarkDone(task) {
            Button {
                if workspace.completionNeedsConfirmation(for: task) { confirmForceComplete = true }
                else { markDone(task) }
            } label: {
                quickActionLabel("Mark done", systemImage: "checkmark")
            }
            .accessibilityIdentifier("taskQuickDone")
        }

        if returningToTodo {
            if canChangeStatus { returnToTodoButton(for: task, in: snapshot, reopening: false) }
        } else if workspace.canMarkDone(task) {
            sendToAgentButton
        }
    }

    private func returnToTodoButton(for task: PhoneTask, in snapshot: PhoneSnapshot, reopening: Bool) -> some View {
        Button {
            queueField(.status(.todo), for: task, in: snapshot)
        } label: {
            quickActionLabel(reopening ? "Reopen task" : "Back to To Do", systemImage: "arrow.uturn.backward")
        }
        .accessibilityIdentifier("taskQuickTodo")
    }

    private var sendToAgentButton: some View {
        Button {
            showSend = true
        } label: {
            quickActionLabel("Send to agent", systemImage: "paperplane")
        }
        .accessibilityHint("Opens agent, model, and comment options")
        .accessibilityIdentifier("taskQuickSend")
    }

    private func markDone(_ task: PhoneTask) {
        do { try workspace.markDone(task); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func quickActionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(colors.actionAccent)
                .accessibilityHidden(true)
            Text(title)
        }
    }

    private func taskReferenceHeader(_ reference: String) -> some View {
        let copied = copiedTaskReference == reference
        let idLabel = Text(reference)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(colors.muted)
            .accessibilityLabel("Task ID \(reference)")
        let copyButton = Button {
            UIPasteboard.general.string = reference
            copiedTaskReference = reference
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(colors.actionAccent)
                    .accessibilityHidden(true)
                Text(copied ? "Copied" : "Copy task ID")
                    .foregroundStyle(colors.text)
            }
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(PhoneActionButtonStyle())
        .fixedSize()
        .accessibilityLabel("Copy task ID")
        .accessibilityValue(copied ? "Copied" : "")

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                idLabel.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 6)
                copyButton
            }
            VStack(alignment: .leading, spacing: 4) {
                idLabel
                copyButton
            }
        }
    }

    @ViewBuilder
    private func properties(for task: PhoneTask, in snapshot: PhoneSnapshot) -> some View {
        let status = workspace.displayedStatus(for: task)
        let projectID = workspace.displayedProject(for: task)
        let priority = workspace.displayedPriority(for: task)
        let due = workspace.displayedDueDate(for: task)
        let dueLabel = due.map(CalendarDay.label) ?? "No due date"
        if snapshot.supportsFieldEditing,
           snapshot.supportsTaskOverrides || workspace.pendingTaskChange(for: task.id) == nil {
            fieldMenu("Project", selected: projectID, choices: snapshot.projects.map(\.id), label: workspace.projectName) {
                queueField(.project($0), for: task, in: snapshot)
            }
            fieldMenu("Status", selected: status,
                      choices: PhoneTask.Status.allCases.filter {
                          snapshot.supportsTaskOverrides || !task.assigned || $0 != .done || $0 == status
                      },
                      label: \.rawValue) {
                if $0 == .sent { showSend = true }
                else if $0 == .done, task.assigned || status == .sent { confirmForceComplete = true }
                else { queueField(.status($0), for: task, in: snapshot) }
            }
            fieldMenu("Priority", selected: priority, choices: PhoneTask.Priority.allCases, label: \.title) {
                queueField(.priority($0), for: task, in: snapshot)
            }
            Button {
                dueDateEdit = DueDateEdit(task: task, workspaceID: snapshot.workspaceID, currentDueDate: due)
            } label: {
                fieldLabel("Due date", value: dueLabel, symbol: "calendar")
            }
            .accessibilityLabel("Due date")
            .accessibilityHint("Opens a calendar")
            .accessibilityValue(dueLabel)
        } else {
            LabeledContent("Project", value: workspace.projectName(projectID))
            LabeledContent("Status", value: status.rawValue)
            LabeledContent("Priority", value: priority.title)
            LabeledContent("Due date", value: dueLabel)
            if !snapshot.supportsFieldEditing {
                Text("Update OpenTalon on your Mac to edit ticket fields.")
                    .font(.caption).foregroundStyle(colors.muted)
            }
        }
    }

    private func fieldMenu<Value: Hashable>(_ title: String, selected: Value, choices: [Value],
                                            label: @escaping (Value) -> String,
                                            change: @escaping (Value) -> Void) -> some View {
        HStack {
            Text(title)
                .layoutPriority(1)
                .accessibilityHidden(true)
            Spacer()
            Menu {
                Picker(title, selection: Binding(get: { selected }, set: { if $0 != selected { change($0) } })) {
                    ForEach(choices, id: \.self) { choice in
                        Text(label(choice)).tag(choice)
                    }
                }
            } label: {
                fieldValue(label(selected), symbol: "chevron.up.chevron.down")
                    .lineLimit(1)
                    .frame(minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: 250, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .tint(colors.text)
            .accessibilityLabel(title)
            .accessibilityValue(label(selected))
        }
        .foregroundStyle(colors.text)
    }

    private func fieldLabel(_ title: String, value: String, symbol: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            fieldValue(value, symbol: symbol)
        }
        .foregroundStyle(colors.text)
        .contentShape(Rectangle())
    }

    private func fieldValue(_ value: String, symbol: String) -> some View {
        HStack {
            Text(value)
            Image(systemName: symbol).font(.caption.weight(.semibold))
                .foregroundStyle(symbol == "calendar" ? colors.actionAccent : colors.text)
        }
    }

    private func queueField(_ edit: PhoneTaskFieldEdit, for task: PhoneTask, in snapshot: PhoneSnapshot) {
        do {
            try workspace.queueField(edit, for: task, in: snapshot.workspaceID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func notes(for task: PhoneTask, in snapshot: PhoneSnapshot) -> some View {
        let canEdit = snapshot.supportsNoteEditing
        let pending = workspace.pendingNotes(for: task.id)
        let text = pending ?? task.notes
        return Section("Notes") {
            if canEdit, workspace.pendingTaskChange(for: task.id) == nil {
                Button {
                    notesEdit = NotesEdit(task: task, workspaceID: snapshot.workspaceID,
                                          unsaved: workspace.unsavedNotes(for: task.id))
                } label: {
                    HStack(alignment: .top) {
                        Text(text.isEmpty ? "Add notes" : text)
                            .foregroundStyle(text.isEmpty ? colors.muted : colors.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "pencil")
                            .foregroundStyle(colors.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the notes editor")
                if workspace.unsavedNotes(for: task.id) != nil {
                    Text("An unsaved edit is ready to review.").font(.caption).foregroundStyle(colors.danger)
                }
            } else {
                if !text.isEmpty { Text(text).textSelection(.enabled) }
                if !canEdit {
                    Text("Update OpenTalon on your Mac to edit notes.")
                        .font(.caption).foregroundStyle(colors.muted)
                } else if pending == nil {
                    Text("Notes can be edited after the current change syncs.")
                        .font(.caption).foregroundStyle(colors.muted)
                }
            }
        }
        .listRowBackground(colors.card)
    }

    private func comments(for task: PhoneTask) -> some View {
        Section("Comments") {
            if let commentsByTask = workspace.snapshot?.commentsByTask {
                ForEach(commentsByTask[task.id] ?? []) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
                        else { Label("Attachment on Mac", systemImage: "paperclip") }
                        Text(commentStatus(entry)).font(.caption).foregroundStyle(colors.muted)
                    }
                }
                ForEach(workspace.pending.filter { $0.taskID == task.id && !$0.changesTask }) { request in
                    if case .comment(_, let text) = request.action {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(text)
                            Label("Waiting for Mac", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    keepCommentDraftOnCancel = false
                    showComment = true
                } label: {
                    PhoneActionLabel(title: commentText.isEmpty ? "Write a comment" : "Continue comment", systemImage: "square.and.pencil")
                }
                if let commentError {
                    Text(commentError).font(.caption).foregroundStyle(colors.danger)
                } else if commentSaved && commentText.isEmpty {
                    savedCommentLabel("Saved").font(.caption)
                }
            } else {
                Text("Update OpenTalon on your Mac to sync ticket comments here.")
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(colors.card)
    }

    private func commentStatus(_ comment: PhoneComment) -> String {
        let name = workspace.snapshot?.macName
        if let date = comment.pickedUpAt.flatMap(TaskCreationOrder.date(from:)) {
            return pickupCaption(macName: name, date: date)
        }
        switch comment.delivery {
        case "queued", "pending": return "Saved on \(name ?? "your Mac") · Waiting for agent"
        case "needs-review": return "Saved on \(name ?? "your Mac") · Agent delivery needs review"
        case "delivered": return "Delivered to agent"
        default:
            let saved = "Saved on \(name ?? "your Mac")"
            guard let date = TaskCreationOrder.date(from: comment.createdAt) else { return saved }
            return "\(saved) · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private var commentEditor: some View {
        CommentEditor(text: $comment, done: { showComment = false }, cancel: {
            keepCommentDraftOnCancel = true
            showComment = false
        }) {
            if commentTooLong {
                Text("Comments can be up to 10,000 characters.").foregroundStyle(colors.danger)
            } else if let commentError {
                Text(commentError).foregroundStyle(colors.danger)
            } else if !commentText.isEmpty, let commentWorkspaceID,
                      workspace.commentDraft(for: taskID, in: commentWorkspaceID) == comment {
                savedCommentLabel("Draft saved")
            }
        }
        .task(id: comment) {
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            saveCommentDraft()
        }
    }

    private func savedCommentLabel(_ title: LocalizedStringKey) -> some View {
        Label {
            Text(title).foregroundStyle(colors.muted)
        } icon: {
            Image(systemName: "checkmark").foregroundStyle(colors.done)
        }
    }

    private func saveCommentDraft() {
        guard let commentWorkspaceID else { return }
        do {
            try workspace.saveCommentDraft(comment, for: taskID, in: commentWorkspaceID)
        } catch {
            commentError = "Couldn’t save the comment draft. \(error.localizedDescription)"
        }
    }

    private func finishComment() {
        guard let commentWorkspaceID, workspace.snapshot?.workspaceID == commentWorkspaceID else { return }
        guard !keepCommentDraftOnCancel, phase == .active, !commentText.isEmpty, !commentTooLong else {
            saveCommentDraft()
            return
        }
        do {
            try workspace.finishComment(commentText, for: taskID, in: commentWorkspaceID)
            comment = ""
            commentSaved = true
            commentError = nil
        } catch {
            commentError = "Couldn’t save the comment. \(error.localizedDescription)"
        }
    }

    private func queue(_ action: PhoneRequest.Action) {
        do {
            try workspace.queue(action)
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }
}

private struct CommentEditor<Status: View>: View {
    @Environment(\.phoneColors) private var colors
    @FocusState private var editing: Bool
    @Binding var text: String
    let done: () -> Void
    let cancel: () -> Void
    @ViewBuilder let status: () -> Status

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Comment")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                editorButton("Cancel", action: cancel)
            }
            TextEditor(text: $text)
                .focused($editing)
                .scrollContentBackground(.hidden)
                .foregroundStyle(colors.text)
                .padding(8)
                .background(colors.card, in: .rect(cornerRadius: 12))
                .frame(minHeight: 44)
                .accessibilityLabel("Comment")
            HStack(spacing: 12) {
                status().font(.caption)
                Spacer(minLength: 0)
                editorButton("Done", action: done)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(colors.canvas.ignoresSafeArea())
        .presentationDetents([.large])
        .task { editing = true }
    }

    private func editorButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(minWidth: 56)
        }
        .buttonStyle(PhoneActionButtonStyle())
    }
}

private struct NotesEditor: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var notes: String
    @State private var error: String?

    let task: PhoneTask
    let workspaceID: UUID
    let unsaved: PhoneWorkspace.UnsavedNotes?

    init(edit: NotesEdit) {
        task = edit.task
        workspaceID = edit.workspaceID
        unsaved = edit.unsaved
        _notes = State(initialValue: edit.unsaved?.text ?? edit.task.notes)
    }

    private var tooLong: Bool { notes.utf16.count > 100_000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit notes").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Button { dismiss() } label: { Text("Cancel").frame(minWidth: 56) }
                    .buttonStyle(PhoneActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            if let unsaved {
                Text(unsaved.message).font(.footnote).foregroundStyle(colors.danger)
                DisclosureGroup("Current notes on Mac") {
                    Text(task.notes.isEmpty ? "No notes" : task.notes)
                        .textSelection(.enabled)
                        .frame(maxHeight: 120)
                }
            }
            TextEditor(text: $notes)
                .focused($editing)
                .scrollContentBackground(.hidden)
                .foregroundStyle(colors.text)
                .padding(8)
                .background(colors.card, in: .rect(cornerRadius: 12))
                .frame(minHeight: 44)
                .accessibilityLabel("Task notes")
            HStack(spacing: 12) {
                if tooLong {
                    Text("Notes can be up to 100,000 characters.")
                        .font(.footnote).foregroundStyle(colors.danger)
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(colors.danger)
                }
                Spacer(minLength: 0)
                Button(action: save) { Text("Save").frame(minWidth: 56) }
                    .buttonStyle(PhoneActionButtonStyle())
                    .disabled(tooLong || notes == task.notes)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(colors.canvas.ignoresSafeArea())
        .presentationDetents([.large])
        .task { editing = true }
        .interactiveDismissDisabled(notes != (unsaved?.text ?? task.notes))
    }

    private func save() {
        do {
            try workspace.queueNotes(notes, for: task, in: workspaceID)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct DueDateEditor: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var error: String?
    let edit: DueDateEdit

    init(edit: DueDateEdit) {
        self.edit = edit
        _date = State(initialValue: edit.currentDueDate.flatMap(CalendarDay.date) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Due date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(colors.actionAccent)
                    .listRowBackground(colors.card)
                if edit.currentDueDate != nil {
                    Button {
                        save(nil)
                    } label: {
                        PhoneActionLabel(title: "Clear due date", systemImage: "calendar.badge.minus")
                    }
                    .listRowBackground(colors.card)
                }
                if let error {
                    Text(error).foregroundStyle(colors.danger).listRowBackground(colors.card)
                }
            }
            .modifier(PhoneListAppearance())
            .navigationTitle("Due date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneActionToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                PhoneActionToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(CalendarDay.key(date)) }
                        .disabled(CalendarDay.key(date) == edit.currentDueDate)
                }
            }
        }
    }

    private func save(_ day: String?) {
        do {
            try workspace.queueField(.dueDate(day), for: edit.task, in: edit.workspaceID)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct QueueView: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors

    var body: some View {
        let agentTasks = (workspace.snapshot?.tasks ?? []).filter {
            workspace.pendingTaskChange(for: $0.id) == nil
                && ($0.status == .sent || ($0.status == .working && $0.assigned))
        }
        List {
            if let notice = workspace.pickupNotice {
                PhonePickupNotice(message: notice).listRowBackground(colors.card)
            }
            if let rejection = workspace.lastRejection {
                Section("Couldn’t apply a change") {
                    Text(rejection).font(.footnote)
                    Button("Dismiss") { workspace.clearRejection() }
                }
                .listRowBackground(colors.card)
            }
            if workspace.pending.isEmpty && agentTasks.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "clock",
                                       description: Text("Tasks and changes waiting for your\u{00A0}Mac."))
            }
            if !workspace.pending.isEmpty {
                Section("Waiting for Mac") {
                    ForEach(workspace.pending) { request in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(workspace.title(for: request)).font(.body.weight(.medium))
                            Group {
                                if let agent = requestedAgent(for: request) {
                                    PhoneAgentLabel(agent: agent, title: "Sending to \(agent.title)")
                                } else {
                                    Text(kind(request)).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            if let message = workspace.waitingMessage(for: request) {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listRowBackground(colors.card)
            }
            if !agentTasks.isEmpty {
                Section("Agent work") {
                    ForEach(agentTasks) { task in
                        TaskLink(task: task, showProject: true, showStatus: true)
                    }
                }
            }
            if let error = workspace.syncError {
                Text(error).font(.footnote).foregroundStyle(.secondary).listRowBackground(colors.card)
            }
        }
        .modifier(PhoneListAppearance())
        .refreshable { await workspace.sync() }
    }

    private func requestedAgent(for request: PhoneRequest) -> PhoneAgent? {
        switch request.action {
        case .send(_, _, let agent), .editField(_, _, .status(.sent, let agent, _, _)),
             .setField(_, _, .status(.sent, let agent, _, _)),
             .create(_, _, _, _, true, _, let agent, _, _, _): agent
        default: nil
        }
    }

    private func kind(_ request: PhoneRequest) -> String {
        switch request.action {
        case .create(_, _, _, _, let send, _, _, _, _, _): send ? "New task for agent" : "New to-do"
        case .send: PhoneTask.Status.sent.mobileStage
        case .complete: "Mark done"
        case .forceComplete: "Mark done anyway"
        case .removeArchived(_, _, let permanently): permanently ? "Delete permanently" : "Move to Trash"
        case .restoreTrashed: "Restore task"
        case .emptyTrash: "Empty Trash"
        case .manageArchive(_, _, let permanently): permanently ? "Delete archived tasks" : "Move archived tasks to Trash"
        case .reorderTask: "Reorder task"
        case .comment: "Post comment"
        case .editNotes: "Edit notes"
        case .editField(_, _, .status(let status, _, _, _)), .setField(_, _, .status(let status, _, _, _)): status.mobileStage
        case .editField(_, _, let edit), .setField(_, _, let edit): edit.label
        }
    }
}

private struct CaptureView: View {
    @Environment(PhoneWorkspace.self) private var workspace
    @Environment(\.phoneColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @FocusState private var ideaFocused: Bool
    @State private var idea = ""
    @State private var title = ""
    @State private var notes = ""
    @State private var definitionOfDone = ""
    @State private var project = ""
    @State private var priority = PhoneTask.Priority.none
    @State private var sendToAgent = false
    @State private var showSend = false
    @State private var dispatchQueued = false
    @State private var draftRequest: Task<Void, Never>?
    @State private var draftError: String?
    @State private var error: String?

    private var trimmedIdea: String { idea.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var savedTitle: String {
        let edited = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited.isEmpty ? trimmedIdea : edited
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Idea") {
                    TextField("Type or dictate what needs doing", text: $idea, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($ideaFocused)
                    Button(action: draftTicket) {
                        if draftRequest != nil {
                            ProgressView("Drafting on this device…")
                        } else {
                            PhoneActionLabel(title: "Draft with Apple Intelligence", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(PhoneActionButtonStyle())
                    .disabled(trimmedIdea.isEmpty || draftRequest != nil || (!title.isEmpty && !notes.isEmpty && !definitionOfDone.isEmpty))
                    if let message = draftError ?? TaskDrafting.unavailableReason {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(colors.card)
                Section("Ticket details") {
                    TextField("Title (optional)", text: $title, axis: .vertical).lineLimit(1...3)
                    TextField("Description and steps", text: $notes, axis: .vertical).lineLimit(2...6)
                    TextField("Definition of done", text: $definitionOfDone, axis: .vertical).lineLimit(2...5)
                    if savedTitle.utf16.count > 500 {
                        Text("Give this ticket a shorter title.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(colors.card)
                Section {
                    Picker("Project", selection: $project) {
                        ForEach(workspace.snapshot?.projects ?? []) { Text($0.name).tag($0.id) }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(PhoneTask.Priority.allCases) { Text($0.title).tag($0) }
                    }
                }
                .listRowBackground(colors.card)
                Section {
                    Toggle("Send to agent", isOn: $sendToAgent)
                        .tint(colors.actionAccent)
                } footer: {
                    if sendToAgent {
                        Text("Review the agent, model, and optional comment before sending.")
                    }
                }
                .listRowBackground(colors.card)
                if let error { Text(error).foregroundStyle(colors.danger).listRowBackground(colors.card) }
            }
            .modifier(PhoneListAppearance())
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneActionToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                PhoneActionToolbarItem(placement: .confirmationAction) {
                    Button(sendToAgent ? "Review send" : "Add", action: add)
                        .disabled(project.isEmpty || savedTitle.isEmpty || draftRequest != nil
                                  || savedTitle.utf16.count > 500 || notes.utf8.count > 8000
                                  || definitionOfDone.utf16.count > 10_000)
                }
            }
            .onAppear {
                project = workspace.snapshot?.projects.first?.id ?? ""
                ideaFocused = true
            }
            .onDisappear { draftRequest?.cancel() }
            .sheet(isPresented: $showSend, onDismiss: {
                if dispatchQueued { dismiss() }
            }) {
                if let snapshot = workspace.snapshot {
                    PhoneAgentChooser(snapshot: snapshot, taskTitle: savedTitle) { agent, model, comment in
                        try queueNewTask(agent: agent, model: model, comment: comment)
                        dispatchQueued = true
                    }
                }
            }
        }
    }

    private func draftTicket() {
        guard draftRequest == nil, !trimmedIdea.isEmpty else { return }
        let input = trimmedIdea
        ideaFocused = false
        draftError = nil
        draftRequest = Task {
            defer { draftRequest = nil }
            do {
                let draft = try await TaskDrafting.expand(input)
                try Task.checkCancellation()
                guard trimmedIdea == input else { return }
                if title.isEmpty { title = draft.title }
                if notes.isEmpty { notes = draft.notes }
                if definitionOfDone.isEmpty { definitionOfDone = draft.definitionOfDone }
            } catch is CancellationError {
                return
            } catch {
                draftError = error.localizedDescription
            }
        }
    }

    private func add() {
        if sendToAgent {
            ideaFocused = false
            showSend = true
            return
        }
        do {
            try queueNewTask()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func queueNewTask(agent: PhoneAgent? = nil, model: String? = nil, comment: String? = nil) throws {
        try workspace.queue(.create(
            projectID: project, title: savedTitle, notes: notes, priority: priority,
            sendToAgent: agent != nil, definitionOfDone: definitionOfDone.isEmpty ? nil : definitionOfDone,
            agent: agent, model: model, dispatchComment: comment
        ))
    }
}

private struct OpenTalonSupporterEmblem: View {
    var size: CGFloat = 120
    var animationID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image("SupporterBadge")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? nil : animationID) { badge, scale in
                badge.scaleEffect(scale)
            } keyframes: { _ in
                LinearKeyframe(0.92, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.48, spring: .bouncy)
            }
            .accessibilityHidden(true)
    }
}

/// Two celebratory fountain bursts, with tumbling confetti and brief glitter flares.
/// Decoration never intercepts Done or any purchase control.
private struct SupporterConfetti: View {
    let accent: Color
    let startedAt: Date
    static let duration = 4.6

    private func variation(_ index: Int, _ channel: Int) -> Double {
        let value = sin(Double(index * 73 + channel * 193) * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private func sparklePath(radius: Double) -> Path {
        var path = Path()
        for point in 0..<8 {
            let angle = Double(point) * .pi / 4 - .pi / 2
            let distance = point.isMultiple(of: 2) ? radius : radius * 0.22
            let position = CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
            if point == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        return path
    }

    private func drawConfetti(_ context: GraphicsContext, size: CGSize, elapsed: Double) {
        let colors: [Color] = [accent, .white, accent.opacity(0.65), Color(red: 1, green: 0.83, blue: 0.49)]
        for index in 0..<150 {
            let delay = variation(index, 1) * 0.32 + (index > 95 ? 0.3 : 0)
            let age = elapsed - delay
            let lifetime = 2.6 + variation(index, 2) * 1.4
            guard age >= 0, age < lifetime else { continue }
            let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
            let originX = direction > 0 ? size.width * 0.03 : size.width * 0.97
            let originY = size.height * (0.84 + variation(index, 3) * 0.12)
            let horizontalSpeed = size.width * (0.4 + variation(index, 4) * 0.65)
            let verticalSpeed = size.height * (0.68 + variation(index, 5) * 0.72)
            let gravity = size.height * (0.84 + variation(index, 6) * 0.2)
            let travel = (1 - exp(-0.38 * age)) / 0.38
            let flutter = sin(age * (5 + variation(index, 7) * 6) + Double(index)) * 15 * min(age, 1)
            let x = originX + direction * horizontalSpeed * travel + flutter
            let y = originY - verticalSpeed * age + 0.5 * gravity * age * age
            let fadeIn = min(1, age * 14)
            let fadeOut = min(1, (lifetime - age) * 2.6)
            let width = 4 + variation(index, 8) * 6
            let height = 7 + variation(index, 9) * 9
            var particle = context
            particle.opacity = fadeIn * fadeOut
            particle.translateBy(x: x, y: y)
            particle.rotate(by: .radians(Double(index) + direction * age * (3 + variation(index, 10) * 8)))
            // Changing face width gives each piece its own tumble in depth.
            particle.scaleBy(x: 0.18 + abs(cos(age * (5 + variation(index, 11) * 7) + Double(index))) * 0.82, y: 1)
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let path = index.isMultiple(of: 7) ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
            particle.fill(path, with: .color(colors[index % colors.count]))
        }
    }

    private func drawGlitter(_ context: GraphicsContext, size: CGSize, elapsed: Double) {
        for index in 0..<38 {
            let delay = 0.25 + variation(index, 12) * 2.3
            let age = elapsed - delay
            let lifetime = 0.4 + variation(index, 13) * 0.6
            guard age >= 0, age < lifetime else { continue }
            let progress = age / lifetime
            let shimmer = sin(progress * .pi)
            let x = size.width * (0.06 + variation(index, 14) * 0.88)
            let y = size.height * (0.12 + variation(index, 15) * 0.76) - age * 15
            let radius = (5 + variation(index, 16) * 9) * shimmer
            var sparkle = context
            sparkle.translateBy(x: x, y: y)
            sparkle.rotate(by: .radians(progress * 0.45))
            var glow = sparkle
            glow.opacity = shimmer * 0.16
            glow.addFilter(.blur(radius: 3))
            glow.fill(sparklePath(radius: radius * 1.3), with: .color(.white))
            sparkle.opacity = shimmer * 0.9
            sparkle.fill(sparklePath(radius: radius), with: .color(index.isMultiple(of: 3) ? accent : .white))
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                guard elapsed >= 0, elapsed < Self.duration else { return }
                drawConfetti(context, size: size, elapsed: elapsed)
                drawGlitter(context, size: size, elapsed: elapsed)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
