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

  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 236)
      Divider()
      mainContent.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Palette.canvas)
    .tint(Palette.accent)
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
      HStack(spacing: 11) {
        Image(systemName: "arrow.up.right").font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white).frame(width: 38, height: 38)
          .background(Palette.accent.gradient, in: RoundedRectangle(cornerRadius: 11))
        VStack(alignment: .leading, spacing: 2) {
          Text("Portside").font(.system(size: 19, weight: .semibold))
          Text("Your workspace, connected").font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }.padding(.top, 43).padding(.horizontal, 23).padding(.bottom, 35)

      HStack {
        Text("SERVERS").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(
          .secondary)
        Spacer()
        Button {
          model.serverEditor = ServerEditorContext()
        } label: {
          Image(systemName: "plus").font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain).help("Add server")
      }.padding(.horizontal, 25).padding(.bottom, 12)

      ScrollView {
        VStack(spacing: 6) {
          ForEach(model.servers) { server in
            Button {
              model.selectedServerID = server.id
            } label: {
              HStack(spacing: 11) {
                Image(systemName: "laptopcomputer").font(.system(size: 17))
                  .foregroundStyle(
                    model.selectedServerID == server.id ? Palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                  Text(server.name).font(.system(size: 12, weight: .medium)).foregroundStyle(
                    .primary
                  ).lineLimit(1)
                  Text(server.host).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle().fill(
                  model.serverStates[server.id]?.isReady == true
                    ? Palette.accent : Color.secondary.opacity(0.35)
                ).frame(width: 6, height: 6)
              }
              .padding(12).contentShape(Rectangle())
              .background(
                model.selectedServerID == server.id ? Palette.accent.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
              .contextMenu {
                Button("Edit Server…") { model.serverEditor = ServerEditorContext(server: server) }
                Button("Remove Server…", role: .destructive) { deletingServer = server }
              }
          }
          if model.servers.isEmpty {
            Text("Your work machines will\nappear here.").font(.system(size: 12)).foregroundStyle(
              .secondary
            )
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
          }
        }.padding(.horizontal, 12)
      }
      Spacer(minLength: 20)
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 7) {
          Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Palette.accent)
          Text("Through your tailnet").font(.system(size: 11, weight: .medium))
        }
        Text("Keep Tailscale connected on\nboth machines.").font(.system(size: 11)).foregroundStyle(
          .secondary
        ).lineSpacing(3)
        Divider().padding(.vertical, 5)
        HStack {
          Text("Portside for Mac")
          Spacer()
          Text("0.1.0").monospacedDigit()
        }
        .font(.system(size: 10)).foregroundStyle(.tertiary)
      }.padding(24)
    }
    .background(.regularMaterial)
  }

  private var mainContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("WORKSPACE", systemImage: "square.grid.2x2").font(
          .system(size: 10, weight: .semibold)
        ).tracking(1.3).foregroundStyle(.secondary)
        Spacer()
        if let server = model.selectedServer {
          Menu {
            Button("Edit Server…") { model.serverEditor = ServerEditorContext(server: server) }
            Button("Remove Server…", role: .destructive) { deletingServer = server }
            Divider()
            Button("Stop All Forwards") { model.stopAll() }.disabled(model.activeCount == 0)
          } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.secondary)
          }.menuStyle(.borderlessButton).frame(width: 24)
        }
      }.padding(.bottom, 26)

      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 9) {
          Text("Port forwards").font(.system(size: 29, weight: .semibold)).tracking(-0.7)
          Text("Your remote apps. Right on localhost.").font(.system(size: 13)).foregroundStyle(
            .secondary)
        }
        Spacer()
        Button {
          if let id = model.selectedServerID {
            model.forwardEditor = ForwardEditorContext(serverID: id)
          } else {
            model.serverEditor = ServerEditorContext()
          }
        } label: {
          Label(model.selectedServer == nil ? "Add server" : "New forward", systemImage: "plus")
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
      }.padding(.bottom, 28)

      HStack(spacing: 12) {
        metric("ACTIVE FORWARDS", value: "\(model.activeCount)", symbol: "arrow.left.arrow.right")
        metric("OPEN CONNECTIONS", value: "\(model.connectionCount)", symbol: "network")
        metric("SAVED SERVERS", value: "\(model.servers.count)", symbol: "laptopcomputer")
      }.padding(.bottom, 25)

      if let server = model.selectedServer {
        connectionBar(server).padding(.bottom, 24)
        HStack {
          Text(
            "\(server.name.uppercased()) · \(model.visibleForwards.count) \(model.visibleForwards.count == 1 ? "FORWARD" : "FORWARDS")"
          )
          .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
          Spacer()
          Text("LOCAL → REMOTE").font(.system(size: 9, weight: .medium)).tracking(1)
            .foregroundStyle(.tertiary)
        }.padding(.bottom, 12)
        if model.visibleForwards.isEmpty {
          emptyForwards
        } else {
          ScrollView {
            LazyVStack(spacing: 11) {
              ForEach(model.visibleForwards) { rule in
                ForwardCard(
                  rule: rule, snapshot: model.snapshot(rule),
                  starting: model.starting.contains(rule.id),
                  toggle: {
                    if model.snapshot(rule).phase == .listening || model.starting.contains(rule.id)
                    {
                      model.stop(rule)
                    } else {
                      Task { await model.start(rule) }
                    }
                  },
                  open: { model.open(rule) },
                  edit: {
                    model.forwardEditor = ForwardEditorContext(rule: rule, serverID: rule.serverID)
                  },
                  remove: { deletingForward = rule })
              }
            }.padding(.bottom, 4)
          }
        }
      } else {
        welcome
      }
      Spacer(minLength: 16)
      HStack(spacing: 7) {
        Image(systemName: "lock.shield").font(.system(size: 11))
        Text("Local listeners stay on this Mac. Traffic travels through Tailscale.").font(
          .system(size: 10))
        Spacer()
        Text("⌘N  New forward").font(.system(size: 10))
      }.foregroundStyle(.tertiary).padding(.top, 18)
    }
    .padding(.horizontal, 34).padding(.top, 37).padding(.bottom, 22)
  }

  private func metric(_ label: String, value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(
          .secondary)
        Spacer(minLength: 3)
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(
          Palette.accent.opacity(0.8))
      }
      Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit()
    }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06)))
  }

  private func connectionBar(_ server: ServerProfile) -> some View {
    let state = model.serverStates[server.id] ?? .unchecked
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "server.rack").foregroundStyle(Palette.accent).font(.system(size: 17))
        VStack(alignment: .leading, spacing: 4) {
          Text(server.name).font(.system(size: 12, weight: .semibold))
          Text("\(server.host):\(server.port)").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary).textSelection(.enabled)
        }
        Spacer()
        if state.isChecking {
          ProgressView().controlSize(.small)
        } else if state.isReady {
          Label("Server ready", systemImage: "checkmark.circle.fill").font(
            .system(size: 11, weight: .medium)
          ).foregroundStyle(Palette.accent)
        }
        Button(state.isReady ? "Check again" : "Check connection") {
          Task { await model.check(server) }
        }
        .controlSize(.small).disabled(state.isChecking)
      }
      if case .failed(let message) = state {
        Label(message, systemImage: "exclamationmark.circle").font(.system(size: 11))
          .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(15)
      .background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
      .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.accent.opacity(0.14)))
  }

  private var welcome: some View {
    VStack(spacing: 15) {
      Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 39, weight: .light))
        .foregroundStyle(Palette.accent).padding(.bottom, 6)
      Text("A shorter path to your work.").font(.system(size: 20, weight: .medium))
      Text(
        "Add your work server, choose an app port, and open it\non this Mac. Each forward runs independently."
      )
      .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      .lineSpacing(4)
      Button("Connect your first server") { model.serverEditor = ServerEditorContext() }
        .buttonStyle(.borderedProminent).padding(.top, 6)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyForwards: some View {
    VStack(spacing: 12) {
      Image(systemName: "arrow.left.arrow.right").font(.system(size: 30, weight: .light))
        .foregroundStyle(Palette.accent)
      Text("Give your app a local address.").font(.system(size: 17, weight: .medium))
      Text(
        "Choose the port your app uses on the server.\nPortside will bring it to localhost on this Mac."
      )
      .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      .lineSpacing(3)
      Button("Create a forward") {
        if let id = model.selectedServerID {
          model.forwardEditor = ForwardEditorContext(serverID: id)
        }
      }
      .buttonStyle(.bordered).padding(.top, 4)
    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 30)
  }
}

private struct ForwardCard: View {
  let rule: ForwardRule
  let snapshot: ForwardSnapshot
  let starting: Bool
  let toggle: () -> Void
  let open: () -> Void
  let edit: () -> Void
  let remove: () -> Void

  private var listening: Bool { snapshot.phase == .listening }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(systemName: "terminal").font(.system(size: 17)).foregroundStyle(
          listening ? Palette.accent : .secondary
        )
        .frame(width: 37, height: 37).background(
          Palette.accent.opacity(listening ? 0.09 : 0.03), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 5) {
          Text(rule.name).font(.system(size: 13, weight: .semibold))
          HStack(spacing: 6) {
            Circle().fill(listening ? Palette.accent : .secondary.opacity(0.4)).frame(
              width: 5, height: 5)
            Text(
              starting
                ? "Connecting…"
                : listening
                  ? "Listening · \(snapshot.connections) \(snapshot.connections == 1 ? "connection" : "connections")"
                  : snapshot.phase == .failed ? "Needs attention" : "Stopped"
            )
            .font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if starting { ProgressView().controlSize(.small) }
        Button(action: open) { Image(systemName: "arrow.up.right.square").font(.system(size: 15)) }
          .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!listening).help(
            "Open in browser")
        Button(starting ? "Cancel" : listening ? "Stop" : "Start", action: toggle)
          .buttonStyle(.bordered).tint(listening ? .secondary : Palette.accent).controlSize(.small)
          .frame(minWidth: 53)
        Menu {
          Button("Edit Forward…", action: edit)
          Button("Copy Local URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rule.browserURL.absoluteString, forType: .string)
          }
          Divider()
          Button("Remove Forward…", role: .destructive, action: remove)
        } label: {
          Image(systemName: "ellipsis").foregroundStyle(.secondary)
        }.menuStyle(.borderlessButton).frame(width: 16)
      }
      HStack(spacing: 10) {
        Text("localhost:\(rule.localPort)").foregroundStyle(listening ? Palette.accent : .primary)
        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
        Text("\(rule.family == .ipv4 ? "127.0.0.1" : "[::1]"):\(rule.remotePort)").foregroundStyle(
          .secondary)
        Spacer()
        if snapshot.receivedBytes > 0 {
          Text(
            ByteCountFormatter.string(
              fromByteCount: Int64(clamping: snapshot.receivedBytes), countStyle: .file)
          ).foregroundStyle(.tertiary)
        }
        if rule.autoStart {
          Image(systemName: "arrow.clockwise").foregroundStyle(.tertiary).help(
            "Starts when Portside opens")
        }
      }.font(.system(size: 11, design: .monospaced)).padding(10)
        .background(Palette.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
      if let error = snapshot.error {
        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(
          .orange
        ).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay(
        RoundedRectangle(cornerRadius: 12).stroke(
          listening ? Palette.accent.opacity(0.25) : .primary.opacity(0.07)))
  }
}
