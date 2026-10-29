import PortsideCore
import SwiftUI

struct ServerEditor: View {
  @ObservedObject var model: AppModel
  let existing: ServerProfile?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var host = ""
  @State private var port = "9417"
  @State private var token = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      EditorHeading(
        title: existing == nil ? "Add a server" : "Server settings",
        subtitle: "Connect to the work machine running Portside.", symbol: "server.rack")
      Form {
        TextField("Name", text: $name, prompt: Text("Work laptop"))
        TextField("Tailscale host", text: $host, prompt: Text("work-laptop or 100.x.y.z"))
          .autocorrectionDisabled()
        TextField("Server port", text: $port).monospacedDigit()
        SecureField(
          existing == nil ? "Server token" : "Replacement token", text: $token,
          prompt: Text(
            existing == nil ? "Paste your server token" : "Leave blank to keep current token"))
      }.formStyle(.grouped).scrollDisabled(true).frame(height: 204)
      Label("Tokens are stored in your Mac's Keychain.", systemImage: "key.horizontal").font(
        .system(size: 11)
      ).foregroundStyle(.secondary)
      if existing != nil {
        Text("Saving changes stops this server's forwards and file transfers.").font(
          .system(size: 11)
        )
        .foregroundStyle(.secondary)
      }
      if let error {
        Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(existing == nil ? "Add server" : "Save changes") { save() }.buttonStyle(
          .borderedProminent
        ).keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 490).tint(Palette.accent)
      .onAppear {
        if let existing {
          name = existing.name
          host = existing.host
          port = String(existing.port)
        }
      }
  }

  private func save() {
    do {
      guard let port = UInt16(port), port > 0 else {
        throw PortsideError.invalid("Enter a server port between 1 and 65535.")
      }
      let profile = ServerProfile(
        id: existing?.id ?? UUID(), name: name, host: host, port: port,
        uploadFolder: existing?.uploadFolder ?? "")
      try model.saveServer(profile, token: token)
      dismiss()
      Task { await model.check(profile) }
    } catch { self.error = error.localizedDescription }
  }
}

struct ForwardEditor: View {
  @ObservedObject var model: AppModel
  let context: ForwardEditorContext
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var localPort = "3000"
  @State private var remotePort = "3000"
  @State private var family: LoopbackFamily = .ipv4
  @State private var autoStart = false
  @State private var startNow = true
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      EditorHeading(
        title: context.rule == nil ? "New port forward" : "Edit port forward",
        subtitle: "Choose where this Mac meets your remote app.", symbol: "arrow.left.arrow.right")
      Form {
        TextField("Name", text: $name, prompt: Text("Web app"))
        LabeledContent("Server") {
          Text(model.servers.first { $0.id == context.serverID }?.name ?? "Unknown")
            .foregroundStyle(.secondary)
        }
        TextField("Local port on this Mac", text: $localPort).monospacedDigit()
        TextField("App port on server", text: $remotePort).monospacedDigit()
        Picker("Server loopback", selection: $family) {
          ForEach(LoopbackFamily.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Start after saving", isOn: $startNow)
        Toggle("Start when Portside opens", isOn: $autoStart)
      }.formStyle(.grouped).scrollDisabled(true).frame(height: 330)
      HStack(spacing: 8) {
        Text("localhost:\(localPort)").foregroundStyle(Palette.accent)
        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
        Text("server:\(remotePort)").foregroundStyle(.secondary)
      }.font(.system(size: 12, design: .monospaced))
      if let error {
        Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save forward") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(
          .defaultAction)
      }
    }.padding(28).frame(width: 490).tint(Palette.accent)
      .onAppear {
        if let rule = context.rule {
          name = rule.name
          localPort = String(rule.localPort)
          remotePort = String(rule.remotePort)
          family = rule.family
          autoStart = rule.autoStart
          startNow = model.snapshot(rule).phase == .listening
        }
      }
  }

  private func save() {
    do {
      guard let local = UInt16(localPort), let remote = UInt16(remotePort) else {
        throw PortsideError.invalid("Enter valid ports between 1 and 65535.")
      }
      let rule = ForwardRule(
        id: context.rule?.id ?? UUID(), serverID: context.serverID, name: name, localPort: local,
        remotePort: remote, family: family, autoStart: autoStart)
      try model.saveForward(rule, startNow: startNow)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

private struct EditorHeading: View {
  let title: String
  let subtitle: String
  let symbol: String
  var body: some View {
    HStack(spacing: 13) {
      Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Palette.accent)
        .frame(width: 43, height: 43).background(
          Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 20, weight: .semibold))
        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
      }
    }
  }
}
