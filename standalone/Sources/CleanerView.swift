import SwiftUI

struct CleanerView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var records: [CleanerAppRecord] = []
    @State private var selectedBundleIDs = Set<String>()
    @State private var searchText = ""
    @State private var sortOrder: CleanerSortOrder = .largestFirst
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var scannedAppCount = 0
    @State private var hasLoaded = false
    @State private var scanID = UUID()
    @State private var activeAlert: CleanerAlert?

    private var filteredRecords: [CleanerAppRecord] {
        let matchingRecords: [CleanerAppRecord]
        if searchText.isEmpty {
            matchingRecords = records
        } else {
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: language.locale
            )
            matchingRecords = records.filter {
                $0.app.displayName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: language.locale
                ).contains(query) || $0.app.bundleID.lowercased().contains(query.lowercased())
            }
        }

        return CleanerCatalog.sorted(
            matchingRecords,
            order: sortOrder,
            size: { $0.displayBytes },
            displayName: { $0.app.displayName },
            stableID: { $0.id }
        )
    }

    private var visibleBundleIDs: [String] {
        filteredRecords.map(\.id)
    }

    private var areAllVisibleRecordsSelected: Bool {
        !visibleBundleIDs.isEmpty && visibleBundleIDs.allSatisfy(selectedBundleIDs.contains)
    }

    private var totalAvailableBytes: Int64 {
        records.reduce(0) { $0 + $1.displayBytes }
    }

    private var selectedBytes: Int64 {
        records.reduce(0) { result, record in
            result + (selectedBundleIDs.contains(record.id) ? record.displayBytes : 0)
        }
    }

    private var isBusy: Bool {
        isScanning || isCleaning
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("cleaner.search"),
                    clearLabel: language.text("common.clear")
                )
                Divider()
                cleanerList
                    .listStyle(.insetGrouped)
            }
            .navigationTitle(language.text("cleaner.title"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar { toolbarContent }
            .alert(item: $activeAlert, content: alert(for:))
            .onAppear {
                if !hasLoaded {
                    hasLoaded = true
                    reload()
                } else {
                    // Returning from a detail page: patch only the rows
                    // whose containers had deletions, in place.
                    refreshDirtyContainers()
                }
            }
        }
    }

    @ViewBuilder
    private var cleanerList: some View {
        if records.isEmpty {
            List { emptySection }
        } else {
            List {
                summarySection
                applicationsSection
            }
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent(language.text("cleaner.available")) {
                Text(sizeText(totalAvailableBytes))
                    .monospacedDigit()
            }
            LabeledContent(language.text("cleaner.selected")) {
                Text(language.text("cleaner.selected_summary", Int64(selectedBundleIDs.count), sizeText(selectedBytes)))
                    .monospacedDigit()
            }
            cleanAction
        } header: {
            Label(language.text("cleaner.limited_mode"), systemImage: "checkmark.shield")
        } footer: {
            Text(language.text("cleaner.scope_footer"))
        }
    }

    private var applicationsSection: some View {
        Section {
            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("browser.search_empty"))
                        .font(.headline)
                    Text(language.text("cleaner.search_empty_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(filteredRecords) { record in
                    cleanerRow(record)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(language.text("cleaner.apps_with_cache", Int64(filteredRecords.count)))
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                    Text(language.text("cleaner.scanned_count", Int64(scannedAppCount)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        } footer: {
            if !records.isEmpty {
                Text(language.text("cleaner.apps_footer"))
            }
        }
    }

    private func cleanerRow(_ record: CleanerAppRecord) -> some View {
        // Navigation rides invisibly behind the row (the List adds its own
        // single disclosure chevron). A visible link plus icon placeholder
        // used to squeeze the name column into truncation.
        ZStack {
            if record.app.bundleID != (Bundle.main.bundleIdentifier ?? "") {
                NavigationLink {
                    CleanerAppInventoryRoot(
                        appName: record.app.displayName,
                        bundleID: record.app.bundleID,
                        containerPath: record.app.containerPath
                    )
                } label: {
                    EmptyView()
                }
                .opacity(0)
                .disabled(isCleaning)
            }

            HStack(spacing: 10) {
                Button {
                    toggleSelection(record.id)
                } label: {
                    Image(systemName: selectedBundleIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: AppTheme.selectionIconSize, weight: .medium))
                        .foregroundStyle(selectedBundleIDs.contains(record.id) ? AppTheme.accent : Color.secondary)
                        .frame(width: 30, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(isCleaning)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.app.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(record.app.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isCleaning { toggleSelection(record.id) }
                }

                Text(sizeText(record.displayBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.vertical, 2)
        }
    }



    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !records.isEmpty {
            ToolbarItem(placement: .navigationBarLeading) {
                selectionMenu
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                sortMenu
                refreshButton
            }
        } else {
            ToolbarItem(placement: .navigationBarLeading) {
                refreshButton
            }
        }
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                selectedBundleIDs = CleanerCatalog.selectingAllVisible(
                    visibleBundleIDs,
                    preserving: selectedBundleIDs
                )
            } label: {
                Label(
                    searchText.isEmpty
                        ? language.text("patch.select_all")
                        : language.text("cleaner.select_all_results"),
                    systemImage: "checkmark.circle"
                )
            }
            .disabled(areAllVisibleRecordsSelected)

            Button {
                selectedBundleIDs.removeAll()
            } label: {
                Label(language.text("patch.deselect_all"), systemImage: "circle")
            }
            .disabled(selectedBundleIDs.isEmpty)
        } label: {
            Image(systemName: "checklist")
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.selection_actions"))
    }

    private var sortMenu: some View {
        Menu {
            Picker(language.text("cleaner.sort"), selection: $sortOrder) {
                Label(
                    language.text("cleaner.sort_largest_first"),
                    systemImage: "arrow.down"
                )
                .tag(CleanerSortOrder.largestFirst)

                Label(
                    language.text("cleaner.sort_smallest_first"),
                    systemImage: "arrow.up"
                )
                .tag(CleanerSortOrder.smallestFirst)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.sort"))
    }

    private var refreshButton: some View {
        Button { reload() } label: {
            if isScanning {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.scan_again"))
    }

    private var cleanAction: some View {
        Button {
            activeAlert = .confirmation
        } label: {
            HStack(spacing: 8) {
                if isCleaning {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "trash")
                }
                Text(
                    isCleaning
                        ? language.text("cleaner.cleaning")
                        : language.text("cleaner.clean_button", sizeText(selectedBytes))
                )
                .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedBundleIDs.isEmpty || isBusy)
        .padding(.vertical, 4)
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 12) {
                if isScanning {
                    ProgressView()
                    Text(language.text("cleaner.scanning"))
                        .font(.headline)
                    Text(language.text("cleaner.scanned_count", Int64(scannedAppCount)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("cleaner.empty_title"))
                        .font(.headline)
                    Text(language.text("cleaner.empty_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(language.text("cleaner.scan_again")) { reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private func alert(for alert: CleanerAlert) -> Alert {
        switch alert {
        case .confirmation:
            return Alert(
                title: Text(language.text("cleaner.confirm_title")),
                message: Text(
                    language.text(
                        "cleaner.confirm_message",
                        Int64(selectedBundleIDs.count),
                        sizeText(selectedBytes)
                    )
                ),
                primaryButton: .destructive(Text(language.text("cleaner.confirm_action"))) {
                    cleanSelectedApps()
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .result(let message):
            return Alert(
                title: Text(language.text("cleaner.result_title")),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        }
    }

    private func toggleSelection(_ bundleID: String) {
        if selectedBundleIDs.contains(bundleID) {
            selectedBundleIDs.remove(bundleID)
        } else {
            selectedBundleIDs.insert(bundleID)
        }
    }

    private func reload() {
        guard !isBusy else { return }
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-empty") {
            records = []
            selectedBundleIDs = []
            scannedAppCount = 388
            isScanning = false
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-data") {
            let samples = [
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.lemon.lvoverseas",
                        name: "CapCut",
                        containerPath: "/tmp/CapCut",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 184_549_376,
                        temporaryBytes: 12_582_912,
                        removableItemCount: 284
                    )
                ),
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.apple.Maps",
                        name: "Maps",
                        containerPath: "/tmp/Maps",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 61_865_984,
                        temporaryBytes: 3_145_728,
                        removableItemCount: 92
                    )
                ),
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.apple.mobilesafari",
                        name: "Safari",
                        containerPath: "/tmp/Safari",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 27_262_976,
                        temporaryBytes: 1_048_576,
                        removableItemCount: 48
                    )
                )
            ]
            records = samples
            selectedBundleIDs = Set(samples.prefix(2).map(\.id))
            scannedAppCount = 388
            isScanning = false
            if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-warning") {
                activeAlert = .confirmation
            }
            return
        }
#endif
        let requestID = UUID()
        scanID = requestID
        isScanning = true
        scannedAppCount = 0
        selectedBundleIDs.removeAll()
        // On a rescan the previous list stays visible until the new one
        // is complete (atomic swap at the end); on first load records
        // stream in in batches as the parallel scan produces them.
        let streamIn = records.isEmpty

        DispatchQueue.global(qos: .userInitiated).async {
            // Phase 1 (serial): collect candidates from every source.
            // API/MCM/MHA apps still need activation during the scan;
            // filesystem-resolved apps arrive with grants and paths.
            var activationCandidates: [InstalledApp] = []
            var directApps: [InstalledApp] = []
            var seenIDs = Set<String>()
            func collect(_ apps: [InstalledApp], into list: inout [InstalledApp]) {
                for app in apps where seenIDs.insert(app.bundleID).inserted {
                    list.append(app)
                }
            }
            let apiApps = ContainerStore.installedAppsFromAPI()
            let dynamicIdentifiers = ContainerStore.dynamicAppIdentifiers()
            let mcmApps = ContainerStore.installedAppsFromMCM(identifiers: dynamicIdentifiers)
            collect(apiApps + mcmApps, into: &activationCandidates)

            let launchServicesIdentifiers = ContainerStore.launchServicesStoreIdentifiers()
            let candidates = MHAIdentifierCatalog.identifiers(
                dynamic: dynamicIdentifiers,
                installed: apiApps.map(\.bundleID),
                research: ContainerStore.researchAppIdentifiers,
                custom: [],
                launchServices: launchServicesIdentifiers
            )
            log("cleaner: resolving \(candidates.count) MHA-C2 bundle candidates")
            let mhaApps = ContainerStore.installedAppsFromMHACandidates(
                identifiers: candidates
            ) { _ in }
            collect(mhaApps, into: &activationCandidates)

            collect(ContainerStore.resolvedFilesystemApps(), into: &directApps)
            log("cleaner: filesystem direct records added=\(directApps.count)")

            // Phase 2 (parallel): activation + cache/tmp usage scan.
            // The filesystem walks dominate the wall time and fan out;
            // worse_query grants stay serialized inside
            // ContainerStore.grantContainerAccess, because every grant
            // rewrites the same group-container symlink.
            let jobs: [(app: InstalledApp, needsActivation: Bool)] =
                activationCandidates.map { ($0, true) } + directApps.map { ($0, false) }
            let collectLock = NSLock()
            var collected: [CleanerAppRecord] = []
            var flushedCount = 0
            var processedCount = 0
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                let job = jobs[index]
                var record: CleanerAppRecord?
                if ContainerPresentationPolicy.shouldShow(bundleID: job.app.bundleID) {
                    let containerPath: String?
                    if job.needsActivation {
                        if let resolved = ContainerStore.resolveAppContainerPath(bundleID: job.app.bundleID),
                           ContainerStore.isApplicationContainerPath(resolved) {
                            containerPath = resolved
                        } else {
                            containerPath = nil
                        }
                    } else {
                        containerPath = job.app.containerPath
                    }
                    if let containerPath,
                       let usage = try? LimitedCleanerService.scan(
                           containerURL: URL(fileURLWithPath: containerPath, isDirectory: true),
                           rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                       ) {
                        record = CleanerAppRecord(
                            app: InstalledApp(
                                bundleID: job.app.bundleID,
                                name: job.app.name,
                                containerPath: containerPath,
                                version: job.app.version,
                                icon: job.app.icon
                            ),
                            usage: usage
                        )
                    }
                }
                collectLock.lock()
                processedCount += 1
                if let record {
                    collected.append(record)
                }
                var batch: [CleanerAppRecord] = []
                if streamIn, collected.count - flushedCount >= 16 {
                    batch = Array(collected[flushedCount...])
                    flushedCount = collected.count
                }
                let processed = processedCount
                collectLock.unlock()
                if !batch.isEmpty {
                    DispatchQueue.main.async {
                        guard scanID == requestID else { return }
                        let known = Set(records.map(\.id))
                        records.append(contentsOf: batch.filter { !known.contains($0.id) })
                        scannedAppCount = processed
                    }
                }
            }

            let finalRecords = collected
            let finalProcessed = processedCount
            DispatchQueue.main.async {
                guard scanID == requestID else { return }
                if streamIn {
                    let known = Set(records.map(\.id))
                    records.append(contentsOf: finalRecords.filter { !known.contains($0.id) })
                } else {
                    records = finalRecords
                }
                scannedAppCount = finalProcessed
                isScanning = false
                log(
                    "cleaner: scan complete bundles=\(finalProcessed) " +
                        "reclaimableApps=\(finalRecords.count)"
                )
                measureFullSizes(finalRecords, requestID: requestID)
            }
        }
    }

    /// Progressive whole-container sizing: the list first appears with
    /// cache/tmp figures, then each row's true footprint (Documents,
    /// Library, everything) lands as it is measured.
    private func measureFullSizes(_ snapshot: [CleanerAppRecord], requestID: UUID) {
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: snapshot.count) { index in
                let record = snapshot[index]
                guard let bytes = ContainerInventoryService.measureContainer(
                    containerPath: record.app.containerPath
                ) else {
                    return
                }
                DispatchQueue.main.async {
                    guard scanID == requestID,
                          let index = records.firstIndex(where: { $0.id == record.id }) else {
                        return
                    }
                    records[index].fullBytes = bytes
                }
            }
        }
    }

    /// Detail pages delete through ContainerInventoryService, which this
    /// list cannot observe; they mark their bundle ID in
    /// CleanerRefreshCenter instead. When the list reappears, only the
    /// marked containers are re-scanned and re-measured (in parallel)
    /// and their rows are patched in place -- no stale sizes, no full
    /// rescan.
    private func refreshDirtyContainers() {
        let dirty = CleanerRefreshCenter.shared.consumeDirty()
        guard !dirty.isEmpty else { return }
        if isBusy {
            // A running clean patches its own rows when it lands; put
            // the marks back so they are not lost. A running scan
            // publishes a fresh snapshot anyway, so marks can drop.
            if isCleaning {
                dirty.forEach { CleanerRefreshCenter.shared.markDirty(bundleID: $0) }
            }
            return
        }
        let targets = records.filter { dirty.contains($0.id) }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let target = targets[index]
                let usage = try? LimitedCleanerService.scan(
                    containerURL: URL(fileURLWithPath: target.app.containerPath, isDirectory: true),
                    rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                )
                let full = ContainerInventoryService.measureContainer(
                    containerPath: target.app.containerPath
                )
                DispatchQueue.main.async {
                    guard let rowIndex = records.firstIndex(where: { $0.id == target.id }) else { return }
                    if let usage {
                        var updated = CleanerAppRecord(app: target.app, usage: usage)
                        updated.fullBytes = full ?? records[rowIndex].fullBytes
                        records[rowIndex] = updated
                    } else if let full {
                        records[rowIndex].fullBytes = full
                    }
                }
            }
        }
    }

    private func cleanSelectedApps() {
        guard !isBusy else { return }
        let selectedRecords = records.filter { selectedBundleIDs.contains($0.id) }
        guard !selectedRecords.isEmpty else { return }
        isCleaning = true

        DispatchQueue.global(qos: .userInitiated).async {
            var updatedUsage: [String: LimitedCleanerUsage] = [:]
            var freedByID: [String: Int64] = [:]
            var freedBytes: Int64 = 0
            var removedItems = 0
            var failedItems = 0
            var unavailableApps = 0

            for record in selectedRecords {
                guard let containerPath = ContainerStore.resolveAppContainerPath(
                    bundleID: record.app.bundleID
                ) else {
                    unavailableApps += 1
                    log("cleaner: bundle unavailable \(record.app.bundleID)")
                    continue
                }

                do {
                    let result = try LimitedCleanerService.clean(
                        containerURL: URL(fileURLWithPath: containerPath, isDirectory: true),
                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) }
                    )
                    updatedUsage[record.id] = result.after
                    freedByID[record.id] = result.freedBytes
                    freedBytes += result.freedBytes
                    removedItems += result.removedItemCount
                    failedItems += result.failedItemCount
                    log(
                        "cleaner: cleaned \(record.app.bundleID) " +
                            "freed=\(result.freedBytes) removed=\(result.removedItemCount) " +
                            "failed=\(result.failedItemCount)"
                    )
                } catch {
                    unavailableApps += 1
                    log("cleaner: failed \(record.app.bundleID) error=\(error)")
                }
            }

            let resultMessage = language.text(
                "cleaner.result_message",
                sizeText(freedBytes),
                Int64(removedItems),
                Int64(failedItems + unavailableApps)
            )
            DispatchQueue.main.async {
                // An app whose cache hit zero still exists (its Documents
                // did not shrink); keep it listed with the freed amount
                // subtracted from its last full size until re-measured.
                records = records.compactMap { record in
                    guard let usage = updatedUsage[record.id] else { return record }
                    var updated = CleanerAppRecord(app: record.app, usage: usage)
                    if let full = record.fullBytes {
                        updated.fullBytes = max(0, full - (freedByID[record.id] ?? 0))
                    }
                    return updated
                }
                selectedBundleIDs.removeAll()
                isCleaning = false
                activeAlert = .result(message: resultMessage)
                measureFullSizes(records, requestID: scanID)
            }
        }
    }

    private func sizeText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

private struct CleanerAppRecord: Identifiable {
    let app: InstalledApp
    let usage: LimitedCleanerUsage
    var fullBytes: Int64?

    var id: String { app.bundleID }

    /// What the list shows: the whole-container size once measured,
    /// the cache/tmp figure until then.
    var displayBytes: Int64 { fullBytes ?? usage.totalBytes }
}

private enum CleanerAlert: Identifiable {
    case confirmation
    case result(message: String)

    var id: String {
        switch self {
        case .confirmation: return "confirmation"
        case .result(let message): return "result-\(message)"
        }
    }
}
