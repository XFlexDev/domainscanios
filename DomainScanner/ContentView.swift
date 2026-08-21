import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Data Models

struct ScanRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let domain: String
    let timestamp: Date
    let duration: TimeInterval
    let subdomains: [String]

    init(id: UUID = UUID(), domain: String, timestamp: Date, duration: TimeInterval, subdomains: [String]) {
        self.id = id
        self.domain = domain
        self.timestamp = timestamp
        self.duration = duration
        self.subdomains = subdomains
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case nameAsc = "Alphabetical (A–Z)"
    case nameDesc = "Alphabetical (Z–A)"
    case lenAsc = "Shortest First"
    case lenDesc = "Longest First"

    var id: String { rawValue }
}

enum ExportType: String, CaseIterable, Identifiable {
    case txt = "Plain Text (.txt)"
    case json = "JSON Payload (.json)"
    case csv = "CSV Spreadsheet (.csv)"

    var id: String { rawValue }
}

// MARK: - Local Notification Manager

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func dispatchCompletionNotification(domain: String, count: Int, duration: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Reconnaissance Complete"
        content.subtitle = domain
        content.body = "Discovered \(count) active endpoints in \(String(format: "%.2f", duration))s."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // Näytä banneri vaikka sovellus olisi etualalla
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

// MARK: - Haptic Engine

final class HapticEngine {
    static let shared = HapticEngine()
    private init() {}

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    func feedbackLight() { light.impactOccurred() }
    func feedbackMedium() { medium.impactOccurred() }
    func feedbackRigid() { rigid.impactOccurred() }
    func feedbackHeavy() { heavy.impactOccurred() }
    func feedbackSuccess() { notification.notificationOccurred(.success) }
    func feedbackSelection() { selection.selectionChanged() }
}

// MARK: - State Store

@MainActor
final class AppStore: ObservableObject {
    @Published var history: [ScanRecord] = []
    @Published var favorites: Set<String> = []
    @Published var activeRecord: ScanRecord?
    @Published var isScanning: Bool = false

    private let historyKey = "recon_history_v6"
    private let favoritesKey = "recon_favorites_v6"

    init() {
        loadStorage()
    }

    func loadStorage() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let records = try? JSONDecoder().decode([ScanRecord].self, from: data) {
            self.history = records
        }
        if let favList = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            self.favorites = Set(favList)
        }
    }

    func recordScan(_ record: ScanRecord) {
        history.removeAll { $0.domain.lowercased() == record.domain.lowercased() }
        history.insert(record, at: 0)
        if history.count > 60 { history = Array(history.prefix(60)) }
        persist()
    }

    func deleteRecord(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persist()
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    func toggleFavorite(_ subdomain: String) {
        if favorites.contains(subdomain) {
            favorites.remove(subdomain)
        } else {
            favorites.insert(subdomain)
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}

// MARK: - Main Interface

struct ContentView: View {
    @StateObject private var store = AppStore()
    private let engine = ScannerEngine()

    @State private var targetInput: String = ""
    @State private var filterQuery: String = ""
    @State private var sortOption: SortOption = .nameAsc
    @State private var onlyFavorites: Bool = false
    @State private var showHistorySheet: Bool = false
    @State private var showExportSheet: Bool = false

    // Snackbar State
    @State private var snackbarText: String?
    @State private var snackbarIcon: String = "checkmark.circle.fill"
    @State private var pulseStream: Bool = false

    private var filteredResults: [String] {
        guard let record = store.activeRecord else { return [] }
        var list = record.subdomains

        if onlyFavorites {
            list = list.filter { store.favorites.contains($0) }
        }

        if !filterQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            list = list.filter { $0.localizedCaseInsensitiveContains(filterQuery) }
        }

        switch sortOption {
        case .nameAsc:
            list.sort()
        case .nameDesc:
            list.sort(by: >)
        case .lenAsc:
            list.sort { $0.count < $1.count }
        case .lenDesc:
            list.sort { $0.count > $1.count }
        }

        return list
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    searchHeaderSection

                    if store.isScanning {
                        telemetryPipelineView
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else if let record = store.activeRecord {
                        dashboardResultsSection(for: record)
                            .transition(.opacity)
                    } else {
                        idleHeroSection
                            .transition(.opacity)
                    }
                }

                // Professional Floating Snackbar
                if let msg = snackbarText {
                    snackbarOverlay(message: msg)
                        .padding(.top, 12)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                        .zIndex(999)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: store.isScanning)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.activeRecord)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: snackbarText)
            .navigationTitle("Intelligence Recon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        HapticEngine.shared.feedbackMedium()
                        showHistorySheet = true
                    } label: {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }

                if store.activeRecord != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                HapticEngine.shared.feedbackSelection()
                                showExportSheet = true
                            } label: {
                                Label("Export Intelligence", systemImage: "square.and.arrow.up")
                            }

                            Button {
                                copyAll()
                            } label: {
                                Label("Copy All Identifiers", systemImage: "doc.on.doc")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                }
            }
            .sheet(isPresented: $showHistorySheet) {
                historySheet
            }
            .sheet(isPresented: $showExportSheet) {
                exportSheet
            }
        }
    }

    // MARK: - Search Header

    private var searchHeaderSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)

                    TextField("Target host (e.g. cloudflare.com)", text: $targetInput)
                        .font(.system(size: 15, weight: .regular, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { executeDiscovery(targetInput) }

                    if !targetInput.isEmpty {
                        Button {
                            HapticEngine.shared.feedbackLight()
                            targetInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(uiColor: .separator).opacity(0.3), lineWidth: 1)
                )

                Button {
                    executeDiscovery(targetInput)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(targetInput.isEmpty || store.isScanning ? Color.secondary.opacity(0.15) : Color.accentColor)
                            .frame(width: 44, height: 42)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(targetInput.isEmpty || store.isScanning ? .secondary : .white)
                    }
                }
                .disabled(targetInput.isEmpty || store.isScanning)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Quick History Chips
            if !store.history.isEmpty && store.activeRecord == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(store.history.prefix(5)), id: \.id) { (item: ScanRecord) in
                            Button {
                                HapticEngine.shared.feedbackSelection()
                                targetInput = item.domain
                                executeDiscovery(item.domain)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 9))
                                    Text(item.domain)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .foregroundColor(.primary)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Live Telemetry Pipeline (Scanning State)

    private var telemetryPipelineView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .opacity(pulseStream ? 1.0 : 0.3)

                    Text("BACKGROUND THREAD ACTIVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())

                Text(targetInput)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
            }

            VStack(spacing: 8) {
                streamStatusRow(feed: "Certificate Transparency", sources: "crt.sh • crt.name")
                streamStatusRow(feed: "Passive DNS & Threat Graph", sources: "AlienVault OTX")
                streamStatusRow(feed: "Host & Infrastructure Search", sources: "HackerTarget • Anubis")
                streamStatusRow(feed: "Historical Web Archive", sources: "Wayback CDX Server")
            }
            .padding(.horizontal, 20)

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 8)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) {
                pulseStream = true
            }
        }
    }

    private func streamStatusRow(feed: String, sources: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(feed)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(sources)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 5, height: 5)
                    .opacity(pulseStream ? 1 : 0.2)
                Text("DISPATCHED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.cyan.opacity(0.08))
            .cornerRadius(4)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator).opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Idle State

    private var idleHeroSection: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle().stroke(Color(uiColor: .separator).opacity(0.3), lineWidth: 1)
                    )

                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 6) {
                Text("Passive Reconnaissance")
                    .font(.system(size: 17, weight: .semibold))
                Text("Execute asynchronous queries across certificate transparency logs, DNS tables, and web archives. Background tasks continue if app is minimized.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .lineSpacing(3)
            }
            Spacer()
        }
    }

    // MARK: - Results Dashboard

    private func dashboardResultsSection(for record: ScanRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                metricBox(title: "IDENTIFIERS", value: "\(record.subdomains.count)", color: .blue)
                metricBox(title: "LATENCY", value: String(format: "%.2fs", record.duration), color: .orange)
                metricBox(title: "APEX DOMAIN", value: record.domain, color: .purple)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("Filter identifiers...", text: $filterQuery)
                        .font(.system(size: 13, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
                )

                Button {
                    HapticEngine.shared.feedbackRigid()
                    onlyFavorites.toggle()
                } label: {
                    Image(systemName: onlyFavorites ? "star.fill" : "star")
                        .foregroundColor(onlyFavorites ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
                        )
                }

                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases) { (opt: SortOption) in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .onChange(of: sortOption) { _ in
                        HapticEngine.shared.feedbackSelection()
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            List {
                Section {
                    ForEach(filteredResults, id: \.self) { (sub: String) in
                        subdomainRow(sub)
                    }
                } header: {
                    Text("\(filteredResults.count) DISCOVERED ENDPOINTS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func metricBox(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
        )
    }

    private func subdomainRow(_ sub: String) -> some View {
        let isFav = store.favorites.contains(sub)

        return HStack(spacing: 8) {
            Text(sub)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)

            Spacer()

            Button {
                HapticEngine.shared.feedbackRigid()
                store.toggleFavorite(sub)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundColor(isFav ? .yellow : Color.secondary.opacity(0.25))
            }
            .buttonStyle(.plain)

            Button {
                copySingle(sub)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button {
                copySingle(sub)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.blue)

            Button {
                HapticEngine.shared.feedbackRigid()
                store.toggleFavorite(sub)
            } label: {
                Label(isFav ? "Unstar" : "Star", systemImage: isFav ? "star.slash" : "star.fill")
            }
            .tint(.yellow)
        }
    }

    // MARK: - Animated Snackbar Component

    private func snackbarOverlay(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: snackbarIcon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.cyan)

            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 16)
        .onTapGesture {
            withAnimation { self.snackbarText = nil }
        }
    }

    // MARK: - History Sheet

    private var historySheet: some View {
        NavigationStack {
            List {
                if store.history.isEmpty {
                    ContentUnavailableView(
                        "No Recon Records",
                        systemImage: "folder.badge.gearshape",
                        description: Text("All gathered targets are preserved locally.")
                    )
                } else {
                    ForEach(store.history, id: \.id) { (rec: ScanRecord) in
                        Button {
                            HapticEngine.shared.feedbackSelection()
                            store.activeRecord = rec
                            targetInput = rec.domain
                            showHistorySheet = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rec.domain)
                                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                                        .foregroundColor(.primary)
                                    Text("\(rec.subdomains.count) records • \(rec.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        HapticEngine.shared.feedbackHeavy()
                        store.deleteRecord(at: offsets)
                    }
                }
            }
            .navigationTitle("Recon History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.history.isEmpty {
                        Button(role: .destructive) {
                            HapticEngine.shared.feedbackHeavy()
                            store.clearHistory()
                        } label: {
                            Text("Clear")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showHistorySheet = false
                    }
                }
            }
        }
    }

    // MARK: - Export Sheet

    private var exportSheet: some View {
        NavigationStack {
            List {
                Section("Format Selection") {
                    ForEach(ExportType.allCases, id: \.id) { (format: ExportType) in
                        Button {
                            HapticEngine.shared.feedbackMedium()
                            exportData(format)
                        } label: {
                            HStack {
                                Text(format.rawValue)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.doc")
                                    .font(.system(size: 13))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Export Telemetry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Dismiss") { showExportSheet = false }
                }
            }
        }
    }

    // MARK: - Background Task & Scan Execution

    private func executeDiscovery(_ domain: String) {
        let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        HapticEngine.shared.feedbackMedium()
        store.isScanning = true

        // 1. Pyydetään iOS:lta tausta-aikaa (Background Task Execution)
        var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "DomainScanner-\(clean)") {
            if backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                backgroundTaskId = .invalid
            }
        }

        Task {
            let res = await engine.scan(apex: clean)
            let newRecord = ScanRecord(
                domain: res.domain,
                timestamp: Date(),
                duration: res.duration,
                subdomains: res.subdomains
            )

            await MainActor.run {
                self.store.activeRecord = newRecord
                self.store.isScanning = false
                self.store.recordScan(newRecord)
                HapticEngine.shared.feedbackSuccess()
                triggerSnackbar("Discovered \(res.subdomains.count) endpoints in \(String(format: "%.2f", res.duration))s")

                // 2. Lähetetään paikallinen ilmoitus käyttäjälle
                NotificationManager.shared.dispatchCompletionNotification(
                    domain: res.domain,
                    count: res.subdomains.count,
                    duration: res.duration
                )

                // 3. Päätetään taustaprosessi
                if backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskId)
                    backgroundTaskId = .invalid
                }
            }
        }
    }

    private func copySingle(_ text: String) {
        UIPasteboard.general.string = text
        HapticEngine.shared.feedbackLight()
        triggerSnackbar("Copied: \(text)")
    }

    private func copyAll() {
        guard let subs = store.activeRecord?.subdomains, !subs.isEmpty else { return }
        UIPasteboard.general.string = subs.joined(separator: "\n")
        HapticEngine.shared.feedbackLight()
        triggerSnackbar("Copied \(subs.count) endpoints")
    }

    private func exportData(_ type: ExportType) {
        guard let subs = store.activeRecord?.subdomains else { return }
        var result = ""

        switch type {
        case .txt:
            result = subs.joined(separator: "\n")
        case .json:
            if let data = try? JSONEncoder().encode(subs), let str = String(data: data, encoding: .utf8) {
                result = str
            }
        case .csv:
            result = "Subdomain\n" + subs.joined(separator: "\n")
        }

        UIPasteboard.general.string = result
        showExportSheet = false
        triggerSnackbar("Exported as \(type.rawValue)")
    }

    private func triggerSnackbar(_ message: String, icon: String = "checkmark.circle.fill") {
        self.snackbarIcon = icon
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.snackbarText = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if self.snackbarText == message {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.snackbarText = nil
                }
            }
        }
    }
}
