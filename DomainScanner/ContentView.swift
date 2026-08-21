import SwiftUI

struct ContentView: View {
    @State private var targetDomain: String = ""
    @State private var filterQuery: String = ""
    @State private var isScanning: Bool = false
    @State private var result: ScanResult?
    
    // Paikallinen tallennustila historialle
    @AppStorage("scan_history") private var historyRaw: String = "[]"
    private let engine = ScannerEngine()

    private var history: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(historyRaw.utf8))) ?? [] }
    }

    private var filteredSubdomains: [String] {
        guard let subs = result?.subdomains else { return [] }
        if filterQuery.isEmpty { return subs }
        return subs.filter { $0.localizedCaseInsensitiveContains(filterQuery) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Hakukenttä
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Syötä apex (esim. apple.com)", text: $targetDomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { startScan(targetDomain) }
                        
                        if isScanning {
                            ProgressView()
                                .padding(.leading, 4)
                        } else if !targetDomain.isEmpty {
                            Button(action: { startScan(targetDomain) }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)

                    // Hakuhistoria
                    if !history.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(history, id: \.self) { item in
                                    Button(item) {
                                        targetDomain = item
                                        startScan(item)
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(UIColor.tertiarySystemBackground))
                                    .foregroundColor(.primary)
                                    .cornerRadius(6)
                                }
                            }
                        }
                    }
                }
                .padding()

                Divider()

                // Tulokset
                if let res = result {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(res.subdomains.count) alidomainia löydetty")
                                .font(.headline)
                            Spacer()
                            Text(String(format: "%.2fs", res.duration))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.top, 10)

                        // Suodatuskenttä
                        if res.subdomains.count > 5 {
                            TextField("Suodata tuloksia...", text: $filterQuery)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)
                                .padding(.bottom, 6)
                        }
                    }

                    List(filteredSubdomains, id: \.self) { sub in
                        Text(sub)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .listStyle(.plain)

                } else {
                    Spacer()
                    Image(systemName: "network")
                        .font(.system(size: 44))
                        .foregroundColor(.tertiaryLabel)
                    Spacer()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let res = result, !res.subdomains.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: res.subdomains.joined(separator: "\n")) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private func startScan(_ domain: String) {
        guard !domain.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isScanning = true
        saveHistory(domain)
        
        Task {
            let res = await engine.scan(apex: domain)
            await MainActor.run {
                self.result = res
                self.isScanning = false
            }
        }
    }

    private func saveHistory(_ domain: String) {
        var current = history.filter { $0 != domain }
        current.insert(domain, at: 0)
        if current.count > 8 { current = Array(current.prefix(8)) }
        if let data = try? JSONEncoder().encode(current) {
            historyRaw = String(data: data, encoding: .utf8) ?? "[]"
        }
    }
}
