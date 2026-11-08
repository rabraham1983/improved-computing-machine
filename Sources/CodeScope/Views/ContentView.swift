import SwiftUI
import CodeScopeCore

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if appState.projectURL == nil {
                WelcomeView()
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
                } content: {
                    centerPane
                        .navigationSplitViewColumnWidth(min: 480, ideal: 760)
                } detail: {
                    AssistantPanel()
                        .navigationSplitViewColumnWidth(min: 340, ideal: 440, max: 640)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
        .toolbar { toolbarContent }
        .alert("CodeScope", isPresented: Binding(get: { appState.errorMessage != nil },
                                                set: { if !$0 { appState.errorMessage = nil } })) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .onChange(of: appState.selectedFilePath) { _, newValue in
            if let newValue, appState.index?.file(at: newValue) != nil, appState.centerTab == .overview {
                appState.centerTab = .code
            }
        }
    }

    @ViewBuilder
    private var centerPane: some View {
        VStack(spacing: 0) {
            switch appState.centerTab {
            case .overview: OverviewView()
            case .code: CodeView()
            case .graph: GraphView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                appState.openProjectPanel()
            } label: {
                Label("Open Project", systemImage: "folder")
            }
            .help("Open a project folder (⌘O)")
        }
        if appState.projectURL != nil {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $appState.centerTab) {
                    ForEach(CenterTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Button {
                        appState.cancelCurrentTask()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .help("Cancel the running request")
                }
                Button {
                    appState.rescan()
                } label: {
                    Label("Re-index", systemImage: "arrow.clockwise")
                }
                .help("Re-read the project from disk (⇧⌘R)")
                .disabled(appState.isScanning)
                Button {
                    appState.centerTab = .overview
                    appState.analyze()
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .help("Explain how the application works (⌘R)")
                .disabled(appState.isBusy || appState.index == nil)
                Button {
                    appState.closeProject()
                } label: {
                    Label("Close Project", systemImage: "xmark.circle")
                }
                .help("Close the project")
            }
        }
    }
}
