import AppKit
import PortsideCore
import SwiftUI

enum Palette {
  static let accent = Color.blue
  static let canvas = Color(nsColor: .windowBackgroundColor)
  static let surface = Color(nsColor: .controlBackgroundColor)
}

private enum WorkspaceTab: String, CaseIterable {
  case overview = "Overview"
  case files = "Files"
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var preferences: AppPreferences
  @State private var selectedForwardID: UUID?
  @State private var tab = WorkspaceTab.overview
  @State private var deletingForward: ForwardRule?
  @State private var deletingServer: ServerProfile?

  private var selectedForward: ForwardRule? {
    model.visibleForwards.first { $0.id == selectedForwardID }
  }
  private var activeCount: Int {
    model.visibleForwards.filter { model.snapshot($0).phase == .listening }.count
  }

  var body: some View {
    NavigationSplitView {
      sidebar.navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 220)
    } content: {
      forwards.navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 340)
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .tint(Palette.accent)
    .onAppear { reconcileSelection() }
    .onChange(of: model.selectedServerID) { _, _ in
      selectedForwardID = model.visibleForwards.first?.id
    }
    .onChange(of: model.visibleForwards.map(\.id)) { _, _ in reconcileSelection() }
    .task(id: model.selectedServerID) {
      if let server = model.selectedServer, model.serverStates[server.id] == nil {
        await model.check(server)
      }
    }
    .sheet(item: $model.serverEditor) { context in
      ServerEditor(model: model, existing: context.server)
    }
    .sheet(item: $model.forwardEditor) { context in ForwardEditor(model: model, context: context) }
    .alert(
      "Something needs attention",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .confirmationDialog(
      "Remove \(deletingForward?.name ?? "forward")?",
      isPresented: Binding(
        get: { deletingForward != nil }, set: { if !$0 { deletingForward = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Forward", role: .destructive) {
        if let rule = deletingForward { model.removeForward(rule) }
        deletingForward = nil
      }
    } message: {
      Text("Its local listener and active connections will close.")
    }
    .confirmationDialog(
      "Remove \(deletingServer?.name ?? "server")?",
      isPresented: Binding(
        get: { deletingServer != nil }, set: { if !$0 { deletingServer = nil } }),
      titleVisibility: .visible
    ) {
      Button("Remove Server", role: .destructive) {
        if let server = deletingServer { model.removeServer(server) }
        deletingServer = nil
      }
    } message: {
      Text("This also removes its saved forwards.")
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: $model.selectedServerID) {
        Section("Servers") {
          ForEach(model.servers) { server in
            HStack(spacing: 9) {
              Image(systemName: "server.rack")
              Text(server.name).lineLimit(1)
              Spacer(minLength: 0)
            }.padding(.vertical, 3).tag(server.id).help(server.host)
              .contextMenu {
                Button("Edit Server…") { editServer(server) }
                Button("Remove Server…", role: .destructive) { deletingServer = server }
              }
          }
          Button("Add Server…", systemImage: "plus") {
            model.serverEditor = ServerEditorContext()
          }.foregroundStyle(.secondary).buttonStyle(.plain).padding(.vertical, 3)
        }
      }.listStyle(.sidebar)
      VStack(alignment: .leading, spacing: 10) {
        HostingStatusLink(host: model.hostedServer, preferences: preferences)
        Label("Via Tailscale", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
          .help("Keep Tailscale connected on both machines.")
      }.padding(12)
    }.navigationTitle("Portside")
  }

  private var forwards: some View {
    VStack(spacing: 0) {
      if model.selectedServer != nil {
        if model.visibleForwards.isEmpty {
          ContentUnavailableView {
            Label("No forwards", systemImage: "arrow.left.arrow.right")
          } description: {
            Text("Add an app port to get started.")
          } actions: {
            Button("New Forward…", action: newForward)
          }
        } else {
          List(selection: $selectedForwardID) {
            ForEach(model.visibleForwards) { rule in
              ForwardListRow(
                rule: rule, snapshot: model.snapshot(rule),
                starting: model.starting.contains(rule.id), toggle: { toggle(rule) }
              )
              .tag(rule.id).contextMenu { forwardActions(rule) }
            }
          }.listStyle(.inset)
        }
        if let server = model.selectedServer { serverFooter(server) }
      } else {
        ContentUnavailableView("Choose a server", systemImage: "server.rack")
      }
    }
    .background(Palette.surface)
    .navigationTitle(model.selectedServer?.name ?? "Forwards")
    .navigationSubtitle("\(activeCount) running")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("New Forward", systemImage: "plus", action: newForward).help("New forward (⌘N)")
        if let server = model.selectedServer {
          Menu("Server Actions", systemImage: "ellipsis.circle") {
            Button("Edit Server…") { editServer(server) }
            Button("Check Connection", systemImage: "arrow.clockwise") {
              Task { await model.check(server) }
            }
            Divider()
            Button("Stop All Forwards") { model.stopAll() }.disabled(model.activeCount == 0)
            Button("Remove Server…", role: .destructive) { deletingServer = server }
          }.menuIndicator(.hidden).help("Server actions")
        }
      }
    }
  }

  private var detail: some View {
    VStack(spacing: 0) {
      if let server = model.selectedServer {
        if tab == .files {
          FileWorkspace(model: model, transfers: model.transfers, server: server).id(server.id)
        } else {
          if let rule = selectedForward {
            ForwardDetailView(
              rule: rule, server: server, snapshot: model.snapshot(rule),
              starting: model.starting.contains(rule.id), toggle: { toggle(rule) },
              edit: { editForward(rule) })
          } else {
            ContentUnavailableView {
              Label("Your apps, connected", systemImage: "arrow.left.arrow.right")
            } description: {
              Text("Forward a port on \(server.name) to localhost on this Mac.")
            } actions: {
              Button("New Forward…", action: newForward)
            }
          }
          FileDropView(model: model, transfers: model.transfers, server: server)
            .id(server.id).padding(12)
        }
      } else {
        ContentUnavailableView {
          Label("Welcome to Portside", systemImage: "network")
        } description: {
          Text("Connect a Tailscale device to bring its apps to localhost.")
        } actions: {
          Button("Add Server…") { model.serverEditor = ServerEditorContext() }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.surface)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Workspace", selection: $tab) {
          ForEach(WorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).frame(width: 180).disabled(model.selectedServer == nil)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        if let rule = selectedForward, tab == .overview {
          Button("Open in Browser", systemImage: "arrow.up.right.square") { model.open(rule) }
            .disabled(model.snapshot(rule).phase != .listening)
            .help(Text(verbatim: "Open localhost:\(rule.localPort) in browser"))
          Menu("Forward Actions", systemImage: "ellipsis") { forwardActions(rule) }
            .menuIndicator(.hidden)
        }
      }
    }
  }

  private func serverFooter(_ server: ServerProfile) -> some View {
    let state = model.serverStates[server.id] ?? .unchecked
    return VStack(alignment: .leading, spacing: 6) {
      Divider().padding(.bottom, 5)
      HStack(spacing: 6) {
        if state.isChecking {
          ProgressView().controlSize(.mini)
        } else {
          Circle().fill(state.isReady ? Palette.accent : .secondary.opacity(0.5))
            .frame(width: 6, height: 6)
        }
        Text(state.isChecking ? "Checking…" : state.isReady ? "Server ready" : "Not connected")
          .font(.system(size: 11, weight: .medium))
        Spacer()
        Button("Check Connection", systemImage: "arrow.clockwise") {
          Task { await model.check(server) }
        }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(state.isChecking)
          .help("Check server connection")
      }
      Text(verbatim: "\(server.host):\(server.port)")
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
      if case .failed(let message) = state {
        Text(message).font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.padding(.horizontal, 14).padding(.bottom, 12)
  }

  @ViewBuilder private func forwardActions(_ rule: ForwardRule) -> some View {
    Button("Edit Forward…") { editForward(rule) }
    Button("Copy Local URL") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(rule.browserURL.absoluteString, forType: .string)
    }
    Divider()
    Button("Remove Forward…", role: .destructive) { deletingForward = rule }
  }
  private func reconcileSelection() {
    if !model.visibleForwards.contains(where: { $0.id == selectedForwardID }) {
      selectedForwardID = model.visibleForwards.first?.id
    }
  }
  private func newForward() {
    if let id = model.selectedServerID {
      model.forwardEditor = ForwardEditorContext(serverID: id)
    } else {
      model.serverEditor = ServerEditorContext()
    }
  }
  private func editServer(_ server: ServerProfile) {
    model.serverEditor = ServerEditorContext(server: server)
  }
  private func editForward(_ rule: ForwardRule) {
    model.forwardEditor = ForwardEditorContext(rule: rule, serverID: rule.serverID)
  }
  private func toggle(_ rule: ForwardRule) {
    if model.snapshot(rule).phase == .listening || model.starting.contains(rule.id) {
      model.stop(rule)
    } else {
      Task { await model.start(rule) }
    }
  }
}

private struct ForwardListRow: View {
  let rule: ForwardRule
  let snapshot: ForwardSnapshot
  let starting: Bool
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.left.arrow.right")
        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        .frame(width: 22, height: 26)
      VStack(alignment: .leading, spacing: 3) {
        Text(rule.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
        HStack(spacing: 5) {
          Text(verbatim: "\(rule.localPort)")
          Image(systemName: "arrow.right").font(.system(size: 8))
          Text(verbatim: "\(rule.remotePort)")
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if snapshot.phase == .failed {
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
          .help(snapshot.error ?? "Forward failed")
      }
      Button(action: toggle) {
        if starting {
          ProgressView().controlSize(.mini).frame(width: 18, height: 18)
        } else {
          Image(systemName: snapshot.phase == .listening ? "stop.fill" : "play.fill")
            .font(.system(size: 12)).frame(width: 18, height: 18)
        }
      }.buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(
          starting
            ? "Cancel starting \(rule.name)"
            : snapshot.phase == .listening ? "Stop \(rule.name)" : "Start \(rule.name)"
        )
        .accessibilityLabel(
          starting
            ? "Cancel \(rule.name)"
            : snapshot.phase == .listening ? "Stop \(rule.name)" : "Start \(rule.name)")
    }.padding(.vertical, 3).contentShape(Rectangle())
  }
}
