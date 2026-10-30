import AppKit
import PortsideCore
import SwiftUI

enum Palette {
  static let accent = Color(red: 0.10, green: 0.48, blue: 0.40)
  static let canvas = Color(nsColor: .windowBackgroundColor)
  static let surface = Color(nsColor: .controlBackgroundColor)
}

struct ContentView: View {
  @ObservedObject var model: AppModel
  @State private var deletingForward: ForwardRule?
  @State private var deletingServer: ServerProfile?

  private var visibleActiveCount: Int {
    model.visibleForwards.filter { model.snapshot($0).phase == .listening }.count
  }

  private var visibleConnectionCount: Int {
    model.visibleForwards.reduce(0) { $0 + model.snapshot($1).connections }
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 184)
        .overlay(alignment: .trailing) {
          Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            .ignoresSafeArea(.container, edges: .vertical).allowsHitTesting(false)
        }
      mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.canvas)
    .tint(Palette.accent)
    .buttonStyle(.glass)
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
      Text("This also removes its saved forwards and Keychain token.")
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white).frame(width: 27, height: 27)
          .background(Palette.accent.gradient, in: RoundedRectangle(cornerRadius: 8))
        Text("Portside").font(.system(size: 16, weight: .semibold))
      }.padding(.top, 18).padding(.horizontal, 16).padding(.bottom, 23)

      HStack {
        Text("SERVERS").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(
          .secondary)
        Spacer()
        Button {
          model.serverEditor = ServerEditorContext()
        } label: {
          Image(systemName: "plus").font(.system(size: 11, weight: .medium))
        }.controlSize(.small).help("Add server")
      }.padding(.horizontal, 17).padding(.bottom, 9)

      ScrollView {
        VStack(spacing: 3) {
          ForEach(model.servers) { server in
            Button {
              model.selectedServerID = server.id
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.system(size: 13))
                  .foregroundStyle(
                    model.selectedServerID == server.id ? Palette.accent : .secondary)
                Text(server.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                  .lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(
                  model.serverStates[server.id]?.isReady == true
                    ? Palette.accent : Color.secondary.opacity(0.35)
                )
                .frame(width: 5, height: 5)
              }.padding(.horizontal, 9).padding(.vertical, 9).contentShape(Rectangle())
                .background(
                  model.selectedServerID == server.id ? Palette.accent.opacity(0.10) : .clear,
                  in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).help(server.host)
              .contextMenu {
                Button("Edit Server…") { model.serverEditor = ServerEditorContext(server: server) }
                Button("Remove Server…", role: .destructive) { deletingServer = server }
              }
          }
          if model.servers.isEmpty {
            Text("Add your work server.").font(.system(size: 11)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(9)
          }
        }.padding(.horizontal, 8)
      }
      Spacer(minLength: 8)
      HStack(spacing: 6) {
        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Palette.accent)
        Text("Via Tailscale")
        Spacer()
        Text(
          Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.3.0"
        )
        .foregroundStyle(.tertiary)
      }.font(.system(size: 10)).foregroundStyle(.secondary).padding(16)
        .help("Keep Tailscale connected on both machines.")
    }.background(.regularMaterial)
  }

  private var mainContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text("Port forwards").font(.system(size: 21, weight: .semibold)).tracking(-0.4)
        Spacer()
        Button {
          if let id = model.selectedServerID {
            model.forwardEditor = ForwardEditorContext(serverID: id)
          } else {
            model.serverEditor = ServerEditorContext()
          }
        } label: {
          Label(model.selectedServer == nil ? "Add server" : "New forward", systemImage: "plus")
        }.buttonStyle(.glassProminent).controlSize(.regular).help("New forward (⌘N)")
        if let server = model.selectedServer {
          Menu {
            Button("Edit Server…") { model.serverEditor = ServerEditorContext(server: server) }
            Button("Remove Server…", role: .destructive) { deletingServer = server }
            Divider()
            Button("Stop All Forwards") { model.stopAll() }.disabled(model.activeCount == 0)
          } label: {
            Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary)
          }.menuStyle(.button).menuIndicator(.hidden).controlSize(.small).frame(width: 26)
            .accessibilityLabel("Server actions")
        }
      }.padding(.bottom, 16)

      if let server = model.selectedServer {
        connectionBar(server).padding(.bottom, 16)
        HStack {
          Text(
            "\(model.visibleForwards.count) \(model.visibleForwards.count == 1 ? "forward" : "forwards")"
          )
          Spacer()
          Text("\(visibleActiveCount) active · \(visibleConnectionCount) connections")
            .monospacedDigit()
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 10)

        if model.visibleForwards.isEmpty { emptyForwards } else { forwardList }
        FileDropView(model: model, transfers: model.transfers, server: server).padding(.top, 12)
      } else {
        welcome
      }
    }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
  }

  private var forwardList: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("NAME").frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
        Text("LOCAL → REMOTE").frame(width: 144, alignment: .leading)
        Text("STATUS").frame(width: 68, alignment: .leading)
        Color.clear.frame(width: 122, height: 1)
      }.font(.system(size: 9, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 9)
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.visibleForwards) { rule in
            ForwardRow(
              rule: rule, snapshot: model.snapshot(rule),
              starting: model.starting.contains(rule.id),
              toggle: {
                if model.snapshot(rule).phase == .listening || model.starting.contains(rule.id) {
                  model.stop(rule)
                } else {
                  Task { await model.start(rule) }
                }
              }, open: { model.open(rule) },
              edit: {
                model.forwardEditor = ForwardEditorContext(rule: rule, serverID: rule.serverID)
              }, remove: { deletingForward = rule })
            if rule.id != model.visibleForwards.last?.id { Divider().padding(.horizontal, 12) }
          }
        }
      }
    }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08)))
  }

  private func connectionBar(_ server: ServerProfile) -> some View {
    let state = model.serverStates[server.id] ?? .unchecked
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "server.rack").font(.system(size: 13)).foregroundStyle(Palette.accent)
        Text(verbatim: "\(server.host):\(server.port)")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          .help(Text(verbatim: "\(server.host):\(server.port)"))
        Spacer(minLength: 4)
        if state.isChecking {
          ProgressView().controlSize(.mini)
        } else if state.isReady {
          Label("Ready", systemImage: "checkmark.circle.fill").font(
            .system(size: 10, weight: .medium)
          )
          .foregroundStyle(Palette.accent).help("The last server connection check succeeded.")
        }
        Button(state.isReady ? "Check" : "Connect") { Task { await model.check(server) } }
          .controlSize(.small).disabled(state.isChecking)
      }
      if case .failed(let message) = state {
        Label(message, systemImage: "exclamationmark.circle").font(.system(size: 11))
          .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(.horizontal, 11).padding(.vertical, 9)
      .background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.accent.opacity(0.12)))
  }

  private var welcome: some View {
    VStack(spacing: 12) {
      Image(systemName: "laptopcomputer").font(.system(size: 28, weight: .light)).foregroundStyle(
        Palette.accent)
      Text("Connect your work server").font(.system(size: 16, weight: .medium))
      Text("Bring its apps to localhost on this Mac.").font(.system(size: 12)).foregroundStyle(
        .secondary)
      Button("Add server") { model.serverEditor = ServerEditorContext() }
        .buttonStyle(.glassProminent).padding(.top, 3)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyForwards: some View {
    VStack(spacing: 10) {
      Text("No forwards yet").font(.system(size: 15, weight: .medium))
      Text("Choose an app port to make it available locally.").font(.system(size: 12))
        .foregroundStyle(.secondary)
      Button("New forward") {
        if let id = model.selectedServerID {
          model.forwardEditor = ForwardEditorContext(serverID: id)
        }
      }.padding(.top, 3)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ForwardRow: View {
  let rule: ForwardRule
  let snapshot: ForwardSnapshot
  let starting: Bool
  let toggle: () -> Void
  let open: () -> Void
  let edit: () -> Void
  let remove: () -> Void

  private var listening: Bool { snapshot.phase == .listening }
  private var status: String {
    if starting { return "Starting…" }
    if listening {
      return snapshot.connections == 0 ? "Listening" : "\(snapshot.connections) conn."
    }
    return snapshot.phase == .failed ? "Failed" : "Stopped"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        HStack(spacing: 7) {
          Circle().fill(
            listening
              ? Palette.accent : snapshot.phase == .failed ? .orange : .secondary.opacity(0.35)
          )
          .frame(width: 5, height: 5)
          Text(rule.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(rule.name)
        }.frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
          Text(verbatim: "\(rule.localPort)").foregroundStyle(listening ? Palette.accent : .primary)
          Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
          Text(verbatim: "\(rule.remotePort)").foregroundStyle(.secondary)
        }.font(.system(size: 11, design: .monospaced)).frame(width: 144, alignment: .leading)
          .help(
            Text(
              verbatim:
                "localhost:\(rule.localPort) → \(rule.family == .ipv4 ? "127.0.0.1" : "[::1]"):\(rule.remotePort)"
            ))
        HStack(spacing: 4) {
          if starting { ProgressView().controlSize(.mini) }
          Text(status).lineLimit(1)
        }.font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 68, alignment: .leading)
          .help("\(snapshot.connections) active TCP connections")
        HStack(spacing: 6) {
          Button(action: open) {
            Image(systemName: "arrow.up.right.square").font(.system(size: 12))
          }
          .controlSize(.small).foregroundStyle(.secondary).disabled(!listening)
          .help(Text(verbatim: "Open localhost:\(rule.localPort) in browser")).accessibilityLabel(
            "Open \(rule.name)")
          Button(starting ? "Cancel" : listening ? "Stop" : "Start", action: toggle)
            .controlSize(.small).frame(width: 56)
          Menu {
            Button("Edit Forward…", action: edit)
            Button("Copy Local URL") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(rule.browserURL.absoluteString, forType: .string)
            }
            Divider()
            Text(
              "Received \(ByteCountFormatter.string(fromByteCount: Int64(clamping: snapshot.receivedBytes), countStyle: .file))"
            )
            if rule.autoStart { Text("Starts when Portside opens") }
            Divider()
            Button("Remove Forward…", role: .destructive, action: remove)
          } label: {
            Image(systemName: "ellipsis").foregroundStyle(.secondary)
          }
          .menuStyle(.button).menuIndicator(.hidden).controlSize(.small).frame(width: 26)
          .accessibilityLabel("Actions for \(rule.name)")
        }.frame(width: 122, alignment: .trailing)
      }.padding(.horizontal, 12).padding(.vertical, 8)
      if let error = snapshot.error {
        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(
          .orange
        )
        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.bottom, 8)
      }
    }
  }
}
