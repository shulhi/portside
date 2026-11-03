import AppKit
import PortsideCore
import SwiftUI

struct HostingStatusLink: View {
  @ObservedObject var host: HostedServer

  var body: some View {
    SettingsLink {
      HStack(spacing: 8) {
        Image(systemName: "desktopcomputer").foregroundStyle(Palette.accent)
        Text("Host this Mac").font(.system(size: 11, weight: .medium))
        Spacer(minLength: 0)
        if host.phase == .running {
          Circle().fill(Palette.accent).frame(width: 5, height: 5)
        }
      }.padding(8).contentShape(Rectangle())
    }.buttonStyle(.plain).help("Make apps on this Mac available to your other devices.")
  }
}

struct HostingSettingsView: View {
  @ObservedObject var host: HostedServer
  @State private var address = ""
  @State private var port = "9417"
  @State private var allowedPorts = "3000,5173,8080"
  @State private var message: String?
  @State private var copied: String?
  @State private var loaded = false

  private var status: String {
    switch host.phase {
    case .stopped: "Stopped"
    case .starting: "Starting…"
    case .running: "Hosting"
    case .stopping: "Stopping…"
    case .failed: "Failed to start"
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 12) {
          Image(systemName: "desktopcomputer").font(.system(size: 23))
            .foregroundStyle(Palette.accent)
          VStack(alignment: .leading, spacing: 4) {
            Text("Host this Mac").font(.system(size: 21, weight: .semibold))
            Text("Open this Mac’s apps from your phone or another computer.")
              .font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }

        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Tailscale IP").font(.system(size: 11, weight: .medium))
              HStack(spacing: 6) {
                TextField("100.x.y.z", text: $address).font(.system(size: 12, design: .monospaced))
                Button("Detect") { detectAddress() }.controlSize(.small)
              }
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("Server port").font(.system(size: 11, weight: .medium))
              TextField("9417", text: $port).font(.system(size: 12, design: .monospaced))
            }.frame(width: 85)
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Allowed app ports").font(.system(size: 11, weight: .medium))
            TextField("3000,5173,8080", text: $allowedPorts)
              .font(.system(size: 12, design: .monospaced))
            Text(
              "Only these ports on this Mac are reachable. You can also use ranges, such as 8000-9000."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
          }
        }.textFieldStyle(.roundedBorder).disabled(host.phase.isActive)

        HStack(spacing: 8) {
          if host.phase == .starting || host.phase == .stopping {
            ProgressView().controlSize(.small)
          } else {
            Circle().fill(host.phase == .running ? Palette.accent : .secondary.opacity(0.4))
              .frame(width: 6, height: 6)
          }
          Text(status).font(.system(size: 12, weight: .medium))
          Spacer()
          if host.phase.isActive {
            Button("Stop server") {
              host.stop()
              message = nil
              copied = nil
            }
            .disabled(host.phase == .stopping)
          } else {
            Button("Start server") {
              message = nil
              copied = nil
              Task {
                do {
                  guard let port = UInt16(port), port > 0 else {
                    throw PortsideError.invalid("Enter a server port between 1 and 65535.")
                  }
                  try await host.start(
                    HostedServerConfiguration(
                      address: address.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                      allowedPorts: allowedPorts.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch { message = error.localizedDescription }
              }
            }.buttonStyle(.glass(.regular.tint(Palette.accent.opacity(0.10))))
          }
        }

        if host.phase == .running {
          VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: host.configuration.endpoint).font(.system(size: 13, design: .monospaced))
              .textSelection(.enabled)
            Text(
              "In Portside on your phone, add this Mac using its IP and server port. Access is limited to devices on your Tailscale account. Keep Tailscale connected on both devices."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
              Button("Copy address") { copy(host.configuration.address, label: "Address copied") }
              if let copied { Text(copied).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.controlSize(.small)
          }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        }

        if let error = message ?? host.errorMessage {
          Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        Text(
          "Hosting and remote forwards work independently. Closing the window keeps hosting active. Quitting Portside stops the server; keep this Mac awake while using its apps remotely."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(24)
    }.frame(width: 520, height: 430)
      .buttonStyle(.glass(.regular.tint(nil))).buttonBorderShape(.capsule)
      .onAppear {
        guard !loaded else { return }
        loaded = true
        address = host.configuration.address
        port = String(host.configuration.port)
        allowedPorts = host.configuration.allowedPorts
        if address.isEmpty { address = HostedServerConfiguration.tailscaleAddresses().first ?? "" }
      }
  }

  private func detectAddress() {
    if let value = HostedServerConfiguration.tailscaleAddresses().first {
      address = value
      message = nil
    } else {
      message = "No Tailscale address was found. Connect Tailscale, then try Detect again."
    }
  }

  private func copy(_ value: String, label: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    copied = label
  }
}
