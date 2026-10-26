import SwiftUI

private enum SettingsSelection: Hashable {
    case general, dock(UUID), about
}
private enum DockSettingsSection: String, CaseIterable {
    case docks = "Docks", appearance = "Appearance", position = "Position", behavior = "Behavior"
}

struct ManageDocksView: View {
    @ObservedObject var manager: DockManager
    @StateObject private var loginItems = LoginItemService()
    @State private var selection: SettingsSelection? = .general

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Settings") {
                        Label("General", systemImage: "gearshape").tag(SettingsSelection.general)
                        Label("About", systemImage: "info.circle").tag(SettingsSelection.about)
                    }
                    Section("Docks") {
                        ForEach(manager.configurations) { dock in
                            HStack {
                                Image(systemName: dock.isEnabled ? "rectangle.stack" : "pause.circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(dock.name.isEmpty ? "Untitled Dock" : dock.name).lineLimit(1)
                                    Text("\(dock.applications.count) \(dock.applications.allSatisfy { $0.kind == .application } ? "apps" : "items") · \(dock.isEnabled ? dock.orientation.rawValue : "disabled")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3).tag(SettingsSelection.dock(dock.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                Button {
                    manager.createDock()
                    if let id = manager.configurations.last?.id { selection = .dock(id) }
                } label: { Label("Create Dock", systemImage: "plus") }
                .padding(12).disabled(manager.isLoading)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let message = manager.storageMessage {
                    ScrollView {
                        Text(message).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(maxHeight: 100).background(.quaternary)
                    Divider()
                }
                switch selection {
                case .general, .none: GeneralSettingsView(manager: manager, loginItems: loginItems)
                case .about: AboutSettingsView()
                case .dock(let id):
                    if let dock = manager.configurations.first(where: { $0.id == id }) {
                        DockSettingsView(manager: manager, dock: dock, selectDuplicate: { selection = .dock($0) }).id(id)
                    } else {
                        ContentUnavailableView("Choose a dock", systemImage: "rectangle.stack",
                            description: Text("Select a dock or create one to customize it."))
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: manager.configurations.map(\.id)) { _, ids in
            if case .dock(let id) = selection, !ids.contains(id) { selection = .general }
        }
        .frame(minWidth: 800, minHeight: 570)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var manager: DockManager
    @ObservedObject var loginItems: LoginItemService

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: Binding(get: { loginItems.isRequested }, set: { enabled in
                    Task { await loginItems.setEnabled(enabled) }
                })).disabled(loginItems.isUpdating)
                Text(loginItems.statusText).font(.callout).foregroundStyle(.secondary)
                if let error = loginItems.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                Button("Open Login Items Settings…") { loginItems.openSystemSettings() }
                Text("Keep MultiDock in Applications before enabling automatic startup. macOS manages login permission; this setting reflects its current status.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Docks") {
                Toggle("Lock all dock positions", isOn: Binding(get: { manager.globalPositionLocked }, set: { manager.setGlobalPositionLocked($0) }))
                Text("The global lock preserves individual dock locks. Display recovery can still reposition inaccessible docks.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Saved docks", value: "\(manager.configurations.count)")
                Toggle("Temporarily hide all docks", isOn: Binding(get: { manager.docksTemporarilyHidden }, set: { value in
                    if value != manager.docksTemporarilyHidden { manager.toggleTemporaryVisibility() }
                }))
                Text("Temporary hiding ends when MultiDock restarts. Disabled docks remain disabled until you enable them.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Enable Auto-hide and Magnification for All Docks") { manager.useDockStyleInteractions() }
                Text("Use a thin hover strip to reveal each dock. Settings remain independent afterward.").font(.caption).foregroundStyle(.secondary)
                Button("Restore Default Layout…", role: .destructive) { manager.requestRestoreDefaultLayout() }
                    .disabled(manager.isLoading)
            }
            Section("Reveal-tab theme") {
                RevealTabStyleEditor(style: Binding(get: { manager.globalRevealStyle }, set: { manager.setGlobalRevealStyle($0) }))
                Text("Applies to hidden-dock reveal tabs using the global theme. Each dock can override this in Appearance → Reveal tab. Dock backgrounds keep their own colors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local storage") {
                Text("Dock settings save automatically on this Mac. Normal Quit finishes pending writes. No account or network connection is used.")
                Text("~/Library/Application Support/org.multidock.MultiDock/docks.json")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItems.refresh() }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                Label("MultiDock", systemImage: "rectangle.stack").font(.largeTitle)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.5")")
                Text("Independent floating docks for macOS 14 or later.")
                Text("Free. Built with SwiftUI and AppKit using public Apple APIs. No third-party dependencies, analytics, cloud service, or subscription.")
                    .foregroundStyle(.secondary)
                Text("Application icons belong to their respective applications. This is an original implementation; no ExtraDock code or assets are included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct DockSettingsView: View {
    @ObservedObject var manager: DockManager
    let dock: DockConfiguration
    let selectDuplicate: (UUID) -> Void
    @State private var section: DockSettingsSection = .docks
    private var current: DockConfiguration { manager.configurations.first { $0.id == dock.id } ?? dock }
    private func appearanceBinding<Value>(_ key: WritableKeyPath<DockAppearance, Value>) -> Binding<Value> {
        Binding(get: { current.appearance[keyPath: key] }, set: { value in
            var appearance = current.appearance
            appearance[keyPath: key] = value
            manager.setAppearance(appearance, in: dock.id)
        })
    }

    private func behaviorBinding<Value>(_ key: WritableKeyPath<DockBehavior, Value>) -> Binding<Value> {
        Binding(get: { current.behavior[keyPath: key] }, set: { value in
            var behavior = current.behavior
            behavior[keyPath: key] = value
            manager.setBehavior(behavior, in: dock.id)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.name.isEmpty ? "Untitled Dock" : current.name).font(.title2.bold())
                    Text("Changes apply only to this dock.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Themes & Colors") { section = .appearance }
                Button("Show") { manager.showDock(dock.id) }.disabled(!current.isEnabled)
            }.padding(20)
            Picker("Dock settings section", selection: $section) {
                ForEach(DockSettingsSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            Form {
                switch section {
                case .docks: dockSection
                case .appearance: appearanceSection
                case .position: positionSection
                case .behavior: behaviorSection
                }
            }.formStyle(.grouped)
        }
    }

    @ViewBuilder private var dockSection: some View {
        Section("Docks") {
            TextField("Name", text: Binding(get: { current.name }, set: { manager.renameDock(dock.id, to: $0) }))
            Toggle("Enable this dock", isOn: Binding(get: { current.isEnabled }, set: { manager.setEnabled($0, in: dock.id) }))
            Picker("Orientation", selection: Binding(get: { current.orientation }, set: { manager.setOrientation(dock.id, to: $0) })) {
                Text("Horizontal").tag(DockOrientation.horizontal)
                Text("Vertical").tag(DockOrientation.vertical)
            }.pickerStyle(.segmented)
            HStack {
                Button("Duplicate Dock") {
                    if let copy = manager.duplicateDock(dock.id) { selectDuplicate(copy) }
                }
                Spacer()
                Button("Delete Dock…", role: .destructive) { manager.requestDeleteDock(dock.id) }
            }
        }
        Section("Applications") {
            HStack {
                Button("Add Applications…") { manager.addApplications(to: dock.id) }
                Button("New App Stack") { manager.createStack(in: dock.id) }
                Button("Add Folder Stack…") { manager.addFolder(to: dock.id) }
            }
            if current.applications.isEmpty { Text("No applications. Add apps here or drop them onto the dock.").foregroundStyle(.secondary) }
            ForEach(Array(current.applications.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Image(nsImage: manager.applicationIcon(item)).resizable().frame(width: 28, height: 28)
                    Text(item.name).lineLimit(1)
                    if item.kind == .application { DockItemTransferMenu(manager: manager, drag: DockItemDrag(dockID: dock.id, itemID: item.id)) }
                    Spacer()
                    Button { manager.moveApplication(item.id, in: dock.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0).help("Move \(item.name) earlier").accessibilityLabel("Move \(item.name) earlier")
                    Button { manager.moveApplication(item.id, in: dock.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == current.applications.count - 1).help("Move \(item.name) later").accessibilityLabel("Move \(item.name) later")
                    Button { manager.removeApplication(item.id, from: dock.id) } label: { Image(systemName: "minus.circle") }
                        .help("Remove \(item.name) from this dock").accessibilityLabel("Remove \(item.name) from this dock")
                }
            }
            Text("Use the arrows to change order, or drag icons on the dock. Removing an entry leaves the installed application untouched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(current.applications.filter { $0.kind == .stack }) { stack in
            Section("App stack") {
                TextField("Stack name", text: Binding(get: { current.applications.first { $0.id == stack.id }?.name ?? stack.name },
                    set: { manager.renameStack(stack.id, in: dock.id, name: $0) }))
                Picker("Stack icon", selection: Binding(get: { current.applications.first { $0.id == stack.id }?.stackSymbol ?? stack.stackSymbol },
                    set: { manager.renameStack(stack.id, in: dock.id, name: stack.name, symbol: $0) })) {
                    ForEach(DockItem.stackSymbols, id: \.self) { symbol in Label(DockItem.symbolTitle(symbol), systemImage: symbol).tag(symbol) }
                }
                Button("Add Applications to Stack…") { manager.addApplications(to: dock.id, stackID: stack.id) }
                StackItemList(manager: manager, dockID: dock.id, stackID: stack.id)
            }
        }
    }

    @ViewBuilder private var positionSection: some View {
        Section("Position locking") {
            Toggle("Lock this dock's position", isOn: behaviorBinding(\.positionLocked))
            Text(manager.globalPositionLocked ? "Locked by the global override in General. Your individual preference is retained." : (current.behavior.positionLocked ? "Position locked. Icons and drag-and-drop remain available." : "Position unlocked. Drag the grip to move this dock."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Position") {
            Picker("Display", selection: Binding(
                get: { current.placement.displayID ?? manager.availableDisplays.first?.id ?? "" },
                set: { manager.placeDock(dock.id, anchor: current.placement.anchor, displayID: $0) })) {
                ForEach(manager.availableDisplays) { display in Text(display.name).tag(display.id) }
                if let preferred = current.placement.displayID, !manager.availableDisplays.contains(where: { $0.id == preferred }) {
                    Text("Disconnected display").tag(preferred)
                }
            }
            Picker("Placement", selection: Binding(get: { current.placement.anchor }, set: { manager.placeDock(dock.id, anchor: $0) })) {
                ForEach(DockAnchor.allCases, id: \.self) { anchor in Text(anchor.title).tag(anchor) }
            }
            Button("Reset Position") { manager.resetPosition(dock.id) }
            Text("Reset centers this dock on its saved display, or on an available display if disconnected. Other docks keep their positions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var behaviorSection: some View {
        Section("Application click behavior") {
            Picker("Click mode", selection: behaviorBinding(\.clickMode)) {
                ForEach(DockClickMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Restore minimized windows", isOn: behaviorBinding(\.restoreMinimizedOnClick))
                .disabled(current.behavior.clickMode == .standard)
            if current.behavior.clickMode != .standard {
                Text("Advanced window selection needs Accessibility access. Until granted, clicks activate normally without prompting. Some apps, full-screen windows and Spaces restrict window control.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Request Accessibility Access…") { manager.requestWindowAccess() }
            }
        }
        Section("Window previews (experimental)") {
            Toggle("Show window previews on hover", isOn: behaviorBinding(\.windowPreviewsEnabled))
            Text("Optional snapshots of a running application's windows appear after a short hover. Without Screen Recording access, use an icon’s Show Window Previews context menu to request it; normal hover stays quiet. Selecting a specific window may also require Accessibility access. Protected, minimized, and other-Space windows may be unavailable. Open Application always remains available.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Magnification") {
            Toggle("Magnify nearby icons", isOn: behaviorBinding(\.magnificationEnabled))
            measurement("Strength", value: behaviorBinding(\.magnificationStrength), range: 0...1, step: 0.05, suffix: "%", multiplier: 100)
                .disabled(!current.behavior.magnificationEnabled)
            measurement("Animation duration", value: behaviorBinding(\.magnificationDuration), range: 0.04...0.4, step: 0.02, suffix: "ms", multiplier: 1000)
                .disabled(!current.behavior.magnificationEnabled)
            Text("Magnification enlarges nearby icons in a wave and moves neighbors aside. The panel stays fixed; shorter duration responds faster. Reduce Motion turns off scaling and show/hide animation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Auto-hide") {
            Toggle("Automatically hide this dock", isOn: behaviorBinding(\.autoHideEnabled))
            measurement("Hide delay", value: behaviorBinding(\.autoHideDelay), range: 0.2...5, step: 0.1, suffix: "s")
                .disabled(!current.behavior.autoHideEnabled)
            measurement("Fade duration", value: behaviorBinding(\.visibilityDuration), range: 0.05...0.5, step: 0.05, suffix: "ms", multiplier: 1000)
            Text("A thin strip remains at a hidden dock. Hover or click it to reveal. Nearby tabs receive separate positions; if no safe space is available, the full dock stays visible. Show in Settings also reveals it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Indicators and collapse") {
            Toggle("Show running-application indicators", isOn: behaviorBinding(\.showsRunningIndicators))
            Toggle("Show collapse control", isOn: behaviorBinding(\.collapseEnabled))
            Toggle("Collapse this dock", isOn: behaviorBinding(\.isCollapsed)).disabled(!current.behavior.collapseEnabled)
            Text("Collapsed docks keep a small tab. Click the tab to expand. Collapsed state is saved; automatic hiding is temporary. Launch feedback uses the accent color while opening, green on success, and red on failure.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Behavior") {
            Toggle("Snap to display edges", isOn: Binding(get: { current.placement.snappingEnabled }, set: { manager.setSnapping($0, in: dock.id) }))
            Toggle("Allow duplicate applications", isOn: Binding(get: { current.allowsDuplicateApplications }, set: { manager.setAllowsDuplicates($0, in: dock.id) }))
            Text("Snapping takes effect when you release the drag handle. Dragging chooses a new home display. A disconnected display's docks use a safe fallback and return when it reconnects.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Dock panels float without taking keyboard focus. Drag icons to organize apps; Option-drag copies an entry between docks. Use the dotted handle to move the panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Appearance", selection: appearanceBinding(\.colorMode)) {
                ForEach(DockColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            measurement("Icon size", value: appearanceBinding(\.iconSize), range: DockAppearance.iconRange, step: 4, suffix: "pt")
            measurement("Spacing", value: appearanceBinding(\.spacing), range: DockAppearance.spacingRange, step: 1, suffix: "pt")
            measurement("Padding", value: appearanceBinding(\.padding), range: DockAppearance.paddingRange, step: 1, suffix: "pt")
        }
        Section("Icon theme") {
            Picker("Icon style", selection: appearanceBinding(\.iconTheme)) {
                ForEach(DockIconTheme.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Tint", selection: appearanceBinding(\.iconTint)) {
                ForEach(DockIconTint.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(current.appearance.iconTheme != .tinted)
            Text("App icons uses macOS's supplied image. Exact Clear/Tinted matching isn't guaranteed; Monochrome and Tinted are MultiDock's local styles.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Background") {
            Picker("Background color", selection: appearanceBinding(\.backgroundColor)) {
                ForEach(DockBackgroundColor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            measurement("Color intensity", value: appearanceBinding(\.backgroundTintStrength), range: 0...1, step: 0.05, suffix: "%", multiplier: 100)
                .disabled(current.appearance.backgroundColor == .material)
            measurement("Opacity", value: appearanceBinding(\.backgroundOpacity), range: DockAppearance.opacityRange, step: 0.05, suffix: "%", multiplier: 100)
            measurement("Corner radius", value: appearanceBinding(\.cornerRadius), range: DockAppearance.radiusRange, step: 1, suffix: "pt")
            Text("Reduce Transparency uses a solid background. Reduce Motion disables drag-return animation; optional icon magnification and dock fades also respect Reduce Motion.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset Appearance") { manager.setAppearance(DockAppearance(), in: dock.id) }
        }
        Section("Reveal tab") {
            Toggle("Use global reveal-tab theme", isOn: Binding(
                get: { current.appearance.revealTabUsesGlobal },
                set: { manager.setRevealStyle(current.appearance.revealTabStyle, usesGlobal: $0, in: dock.id) }))
            RevealTabStyleEditor(style: Binding(get: { current.appearance.effectiveRevealStyle(global: manager.globalRevealStyle) }, set: {
                manager.setRevealStyle($0, usesGlobal: current.appearance.revealTabUsesGlobal, in: dock.id)
            })).disabled(current.appearance.revealTabUsesGlobal)
            Text(current.appearance.revealTabUsesGlobal
                 ? "Using General → Reveal-tab theme. Turn this off to choose a separate tab color and opacity."
                 : "Only this dock's reveal tab changes. Your custom style is retained when you switch to the global theme.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func measurementText(_ value: Double, multiplier: Double, suffix: String) -> String {
        suffix == "s" ? String(format: "%.1f s", value) : "\(Int((value * multiplier).rounded())) \(suffix)"
    }

    private func measurement(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                             suffix: String, multiplier: Double = 1) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 10)
            Slider(value: value, in: range, step: step) { Text(label) }
                .labelsHidden().accessibilityLabel(label)
                .accessibilityValue(measurementText(value.wrappedValue, multiplier: multiplier, suffix: suffix))
                .frame(minWidth: 120, maxWidth: 220)
            Text(measurementText(value.wrappedValue, multiplier: multiplier, suffix: suffix))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }.accessibilityElement(children: .contain)
    }
}

private struct RevealTabStyleEditor: View {
    @Binding var style: DockRevealStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Picker("Tab color", selection: $style.color) {
            ForEach(DockBackgroundColor.allCases, id: \.self) { color in
                Text(color == .material ? "System adaptive" : color.title).tag(color)
            }
        }
        HStack {
            Text("Tab opacity")
            Spacer(minLength: 10)
            Slider(value: $style.opacity, in: 0.25...1, step: 0.05) { Text("Tab opacity") }
                .labelsHidden().accessibilityLabel("Tab opacity")
                .accessibilityValue("\(Int((style.opacity * 100).rounded())) percent")
                .frame(minWidth: 120, maxWidth: 220)
            Text("\(Int((style.opacity * 100).rounded()))%")
                .monospacedDigit().frame(width: 45, alignment: .trailing)
        }
        HStack {
            Text("Preview")
            Spacer()
            Capsule().fill(Color(nsColor: style.color.revealTabColor)
                .opacity(style.effectiveOpacity(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.3), lineWidth: 1))
                .frame(width: 64, height: 10)
                .accessibilityLabel("Reveal-tab color preview")
        }
        Text("Tabs highlight on hover. Reduce Transparency and Increase Contrast keep tabs opaque for visibility.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
