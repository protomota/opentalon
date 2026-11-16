import AuthenticationServices
import CompanionCore
import SwiftUI
import StoreKit

struct OpenTalonSupportTicketsView: View {
    @StateObject private var store = OpenTalonSupportStore()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneColors) private var colors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var nonce = ""
    private enum RequestPresentation: String, Identifiable {
        case purchased, existing
        var id: Self { self }
    }
    @State private var requestPresentation: RequestPresentation?
    @State private var confirmingDeletion = false
    @State private var submittedTicketID: String?
    @State private var ticketToDelete: OpenTalonSupportTicket?
    var body: some View {
        NavigationStack {
            Group {
                if let requestPresentation {
                    newRequest(showCelebration: requestPresentation == .purchased)
                } else if let ticket = store.selectedTicket {
                    conversation(ticket)
                } else if store.account != nil {
                    accountView
                } else {
                    signInView
                }
            }
            .navigationTitle(requestPresentation == nil ? "OpenTalon Support" : "New support request")
            .navigationBarTitleDisplayMode(requestPresentation == nil ? .automatic : .inline)
            .toolbar {
                PhoneActionToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        if requestPresentation != nil { closeRequest() }
                        else { dismiss() }
                    }
                    .accessibilityIdentifier("supportCancel")
                }
            }
            .foregroundStyle(colors.text)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let notice = store.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(colors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(colors.canvas)
                        .accessibilityIdentifier("supportNotice")
                }
            }
            .background(colors.canvas.ignoresSafeArea())
        }
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 840, minHeight: 650)
        .onDisappear { store.cancelBrowserSignIn() }
        #endif
        .tint(colors.actionAccent)
        .phoneConfirmation(
            "Delete your support account?", isPresented: $confirmingDeletion,
            message: "This permanently deletes your support profile, tickets and conversations. Unused tickets will no longer be available. Your workspace stays on your devices. Deletion does not request a refund; unlinked transaction references are retained to reconcile purchases and prevent reuse.",
            confirm: "Delete Support Account", cancel: "Keep My Account", role: .destructive
        ) {
            Task { await store.deleteAccount() }
        }
        .phoneConfirmation("Delete this conversation?", isPresented: Binding(
            get: { ticketToDelete != nil },
            set: { if !$0 { ticketToDelete = nil } }
        ), message: "“\(ticketToDelete?.subject ?? "")” and its messages will be permanently deleted. Your other tickets will stay in your history. This does not refund or restore the purchase.",
        confirm: "Delete conversation", role: .destructive, confirmID: "supportConfirmDeleteConversation") {
            [ticketToDelete] in
            guard let ticketToDelete else { return }
            Task { await store.deleteConversation(ticketToDelete) }
        }
        .onChange(of: store.requestUnlocked) { _, unlocked in
            if unlocked { requestPresentation = .purchased }
        }
        .onChange(of: store.selectedTicketID) { _, id in
            if id != nil && requestPresentation != nil { submittedTicketID = id }
            if id != nil { closeRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in store.signOut() }
        .task {
            await store.load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                if scenePhase == .active { await store.refresh() }
            }
        }
    }

    private var accountView: some View {
        Form {
            Section {
                PhoneActionLabel(title: "Personal help from a real person", systemImage: "person.bubble.left.and.bubble.right")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                Text("Get personal help with OpenTalon on Mac, iPhone, or iPad, including MCP setup. Each ticket opens a private conversation with OpenTalon Support.")
                if let price = store.ticketPrice {
                    Text("\(price) per ticket · One-time purchase").font(.callout.weight(.semibold))
                }
                Text("One ticket covers one issue and its follow-up replies.").font(.callout).foregroundStyle(colors.muted)
            }
            .listRowBackground(colors.card)
            if let account = store.account {
                Section("Your Apple account") {
                    LabeledContent("Contact email", value: account.user.email).textSelection(.enabled)
                    Text("This verified contact address comes from Apple and cannot be edited in your support request.")
                        .font(.caption).foregroundStyle(colors.muted)
                    Button { store.signOut() } label: {
                        PhoneActionLabel(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(store.busy)
                    Button("Delete support account", role: .destructive) { confirmingDeletion = true }
                        .disabled(store.busy).accessibilityIdentifier("supportDeleteAccount")
                }
                .listRowBackground(colors.card)
                Section("Open a support request") {
                    if !store.unusedPurchases.isEmpty {
                        Button { requestPresentation = .existing } label: {
                            PhoneActionLabel(title: "Write your support request", systemImage: "square.and.pencil")
                        }
                            .buttonStyle(PhoneActionButtonStyle())
                            .accessibilityIdentifier("supportWriteRequest")
                        Text("You have a purchased ticket available.").font(.caption).foregroundStyle(colors.muted)
                    } else {
                        Button {
                            #if DEBUG && targetEnvironment(simulator)
                            if store.isDesignPreview { Task { await store.previewPurchasedTicket() }; return }
                            #endif
                            Task { await store.buyAppStoreTicket() }
                        } label: {
                            PhoneActionLabel(
                                title: LocalizedStringKey(store.ticketPrice.map { "Buy one ticket · \($0)" } ?? "Support purchase unavailable"),
                                systemImage: "ticket"
                            )
                        }
                        .buttonStyle(PhoneActionButtonStyle())
                        .disabled(!canBuyTicket)
                        .accessibilityIdentifier("supportBuyAppStoreTicket")
                        if store.ticketPrice == nil && !store.busy {
                            Text("The App Store didn’t return a price. We’ll check again automatically.")
                                .font(.caption).foregroundStyle(colors.muted)
                        }
                    }
                    if store.busy { ProgressView("Working…") }
                }
                .listRowBackground(colors.card)
                Section("Your support tickets") {
                    if account.tickets.isEmpty {
                        Text("Your requests and conversations will appear here.").foregroundStyle(colors.muted)
                    }
                    ForEach(account.tickets) { ticket in
                        Button { Task { await store.open(ticket) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ticket.subject).font(.headline)
                                Text("\(ticket.reference) · \(status(ticket.status))").font(.caption).foregroundStyle(colors.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("supportTicket-\(ticket.id)")
                    }
                    if account.nextOffset != nil {
                        Button("Load more tickets") { Task { await store.moreTickets() } }.disabled(store.busy)
                    }
                }
                .listRowBackground(colors.card)
            }
            Section {
                Text("All OpenTalon features are free. Personal support and tips are optional paid purchases. Bug reports and purchase help do not require a paid ticket.")
                    .font(.caption).foregroundStyle(colors.muted)
                Text("Your workspace stays on your devices. Only the text you choose to submit is shared with support.")
                    .font(.caption).foregroundStyle(colors.muted)
                supportPrivacyLink
            }
            .listRowBackground(colors.card)
            Section("Apple authorization") {
                appleAccountLink
                Text("After deleting your support account, open Apple Account → Sign-In and Security → Sign in with Apple → OpenTalon → Stop Using Sign in with Apple to remove Apple’s authorization too.")
                    .font(.caption).foregroundStyle(colors.muted)
            }
            .listRowBackground(colors.card)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("supportAccountForm")
    }

    private var signInView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "lifepreserver.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(colors.actionAccent)
                        .frame(width: 44, height: 44)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    Text("Personal technical support")
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Get help with OpenTalon on Mac, iPhone, or iPad, including MCP setup. One ticket covers one issue and its follow-up replies in a private conversation.")
                        .foregroundStyle(colors.muted)
                    Text(store.ticketPrice.map { "\($0) per ticket · One-time purchase" } ?? "$9.99 USD per ticket · One-time purchase")
                        .font(.callout.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in to continue")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Use your Apple account to buy a ticket and follow replies. Hide My Email works too.")
                        .font(.callout)
                        .foregroundStyle(colors.muted)
                    appleSignInControl
                    if !store.available && !store.busy {
                        Text("Personal support is currently unavailable. Please try again later.")
                            .font(.caption)
                            .foregroundStyle(colors.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(colors.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(colors.line)
                        .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Personal support is optional. Bug reports and purchase help don’t require a paid ticket.")
                        .foregroundStyle(colors.muted)
                    Text("Your workspace stays on your devices. Only what you send in a ticket is shared with support.")
                        .foregroundStyle(colors.muted)
                    supportPrivacyLink
                    appleAccountLink
                }
                .font(.callout)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("supportSignInScreen")
    }

    private var supportPrivacyLink: some View {
        supportLink("Support privacy", symbol: "lock.shield", url: "https://protomota.com/privacy")
    }

    private var appleAccountLink: some View {
        supportLink("Manage Sign in with Apple", symbol: "apple.logo", url: "https://account.apple.com/account/manage/section/sign-in-and-security")
    }

    private func supportLink(_ title: LocalizedStringKey, symbol: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 10) {
                PhoneActionLabel(title: title, systemImage: symbol)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.actionAccent)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appleSignInControl: some View {
        SignInWithAppleButton(.signIn) { request in
            nonce = OpenTalonSupportStore.nonce()
            request.requestedScopes = [.email]
            request.nonce = OpenTalonSupportStore.hashedNonce(nonce)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                    store.notice = "Apple sign-in could not finish. Please try again."; return
                }
                Task { await store.signIn(token: token, nonce: nonce) }
            case .failure(let error):
                if (error as? ASAuthorizationError)?.code != .canceled { store.notice = "Apple sign-in could not finish. Please try again." }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .clipShape(Capsule())
        .frame(maxWidth: 340).frame(height: 46)
        .disabled(!store.available || store.busy)
        .accessibilityIdentifier("supportSignInWithApple")
    }

    private var canBuyTicket: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if store.isDesignPreview { return true }
        #endif
        return store.canBuy
    }
    private func status(_ value: String) -> String {
        switch value {
        case "in_progress": return "In progress"
        case "waiting_for_customer": return "Your reply needed"
        case "resolved": return "Resolved"
        default: return "Waiting for support"
        }
    }
    private func conversation(_ ticket: OpenTalonSupportTicket) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { store.selectedTicketID = nil } label: {
                        PhoneActionLabel(title: "All tickets", systemImage: "chevron.left")
                    }
                        .buttonStyle(PhoneActionButtonStyle())
                        .accessibilityIdentifier("supportAllTickets")
                    Spacer()
                    Menu {
                        if ticket.status != "resolved" {
                            Button("Mark as resolved", systemImage: "checkmark.circle") {
                                Task { await store.resolveTicket(ticket) }
                            }
                        }
                        Button("Delete conversation…", systemImage: "trash", role: .destructive) { ticketToDelete = ticket }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                            .foregroundStyle(colors.actionAccent)
                    }
                    .accessibilityLabel("Ticket actions")
                    .accessibilityIdentifier("supportTicketActions")
                    .disabled(store.busy)
                }
                Text(ticket.subject).font(.title3.bold())
                Text("\(ticket.reference) · \(status(ticket.status))").font(.caption).foregroundStyle(colors.muted)
                Label("Private conversation with OpenTalon Support", systemImage: "person.fill")
                    .font(.caption).foregroundStyle(colors.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
            if submittedTicketID == ticket.id {
                Label("Your request was sent to Protomota. Check this ticket or your Apple account email for confirmation.",
                      systemImage: "checkmark.circle")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding()
                    .accessibilityIdentifier("supportRequestSent")
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.hasEarlierMessages {
                            Button("Load earlier messages") { Task { await store.earlierMessages() } }.disabled(store.busy)
                        }
                        ForEach(store.messages) { message in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(message.senderRole == "support" ? "OpenTalon Support" : "You").font(.caption.bold())
                                Text(message.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(colors.actionAccent.opacity(message.senderRole == "support" ? 0.45 : 0.25)))
                            .frame(maxWidth: .infinity, alignment: message.senderRole == "support" ? .leading : .trailing)
                            .id(message.id)
                        }
                    }.padding()
                }
                .onChange(of: store.messages.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            Divider()
            if ticket.status == "resolved" {
                Label("This ticket is resolved. You can still read the conversation.", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(colors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("supportResolvedTicket")
            } else {
                replyComposer(ticket)
            }
        }
    }
    private func replyComposer(_ ticket: OpenTalonSupportTicket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                Text("Reply in this ticket").font(.caption).foregroundStyle(colors.muted)
                TextEditor(text: Binding(get: { store.replyDrafts[ticket.id] ?? "" }, set: { store.replyDrafts[ticket.id] = String($0.prefix(10000)) }))
                    .frame(minHeight: 70, maxHeight: 110).padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
                    .disabled(store.busy).accessibilityIdentifier("supportReplyText")
                HStack {
                    Text("Replies stay with this issue.").font(.caption).foregroundStyle(colors.muted)
                    Spacer()
                    Button { Task { await store.reply() } } label: {
                        PhoneActionLabel(title: "Send reply", systemImage: "paperplane.fill")
                    }
                        .buttonStyle(PhoneActionButtonStyle())
                        .disabled(store.busy || (store.replyDrafts[ticket.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ticket.purchase?.status != "paid")
                        .accessibilityIdentifier("supportSendReply")
                }
        }.padding()
    }
    @State private var subject = ""
    @State private var topic = "MCP setup"
    @State private var requestBody = ""
    private func closeRequest() {
        requestPresentation = nil
        store.requestUnlocked = false
    }

    private func newRequest(showCelebration: Bool) -> some View {
        Form {
            if showCelebration {
                Section { SupportTicketReadyHeader() }
                    .listRowBackground(colors.card)
            }
            Section {
                if let email = store.account?.user.email {
                    LabeledContent("Apple contact email", value: email)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("supportAppleContact")
                }
                Text("One ticket covers one OpenTalon issue and its follow-up conversation.").font(.caption).foregroundStyle(colors.muted)
            }
            .listRowBackground(colors.card)
            Section("Your request") {
                TextField("Subject", text: $subject).onChange(of: subject) { _, value in subject = String(value.prefix(140)) }
                Picker("Topic", selection: $topic) {
                    ForEach(["MCP setup", "Projects and tasks", "iCloud sync", "Another OpenTalon issue"], id: \.self) { Text($0) }
                }
                .tint(colors.text)
                TextEditor(text: $requestBody).frame(minHeight: 180)
                    .onChange(of: requestBody) { _, value in requestBody = String(value.prefix(10000)) }
                    .accessibilityIdentifier("supportRequestText")
                Text("Describe what you tried and what happened. Your device and OpenTalon version help too. Notes and transcripts are never attached automatically.")
                    .font(.caption).foregroundStyle(colors.muted)
                Button {
                    #if DEBUG && targetEnvironment(simulator)
                    if store.isDesignPreview { store.previewSubmittedRequest(subject: subject, topic: topic, body: requestBody); return }
                    #endif
                    Task { await store.openRequest(subject: subject, topic: topic, message: requestBody) }
                } label: {
                    PhoneActionLabel(title: "Send support request", systemImage: "paperplane")
                }
                .buttonStyle(PhoneActionButtonStyle())
                .disabled(store.busy || store.unusedPurchases.isEmpty || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("supportSubmitRequest")
            }
            .listRowBackground(colors.card)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct SupportTicketReadyHeader: View {
    @Environment(\.phoneColors) private var colors

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.largeTitle)
                .foregroundStyle(colors.actionAccent)
            Text("Your support ticket is ready").font(.title3.bold())
                .accessibilityIdentifier("supportTicketReady")
            Text("Send your request below. We’ll email confirmation to your Apple account address.")
                .font(.callout).foregroundStyle(colors.muted)
            Text("OpenTalon Support")
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("supportTicketBadge")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
