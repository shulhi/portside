import PortsideCore
import SwiftUI

struct ForwardDetailView: View {
  let rule: ForwardRule
  let server: ServerProfile
  let snapshot: ForwardSnapshot
  let starting: Bool
  let toggle: () -> Void
  let edit: () -> Void

  private var listening: Bool { snapshot.phase == .listening }
  private var status: String {
    if starting { return "Starting…" }
    switch snapshot.phase {
    case .starting: return "Starting…"
    case .listening: return "Listening"
    case .failed: return "Failed"
    case .stopped: return "Stopped"
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 10) {
          Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.accent)
            .frame(width: 34, height: 34)
            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
          VStack(alignment: .leading, spacing: 5) {
            Text(rule.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
            HStack(spacing: 5) {
              Circle().fill(
                listening
                  ? Palette.accent : snapshot.phase == .failed ? .orange : .secondary.opacity(0.4)
              )
              .frame(width: 6, height: 6)
              Text(status).foregroundStyle(.secondary)
            }.font(.system(size: 12))
          }
          Spacer(minLength: 4)
          Button(starting ? "Cancel" : listening ? "Stop" : "Start", action: toggle)
            .buttonStyle(.glass).controlSize(.small)
        }
        VStack(spacing: 0) {
          endpoint("This Mac", address: "localhost:\(rule.localPort)", symbol: "laptopcomputer")
          HStack(spacing: 10) {
            Image(systemName: "arrow.down").font(.system(size: 10)).frame(width: 28)
            Rectangle().fill(.quaternary).frame(height: 1)
            Text("Tailscale").font(.system(size: 10))
            Rectangle().fill(.quaternary).frame(height: 1)
          }.foregroundStyle(.tertiary).padding(.horizontal, 14)
          endpoint(
            server.name,
            address: "\(rule.family == .ipv4 ? "127.0.0.1" : "[::1]"):\(rule.remotePort)",
            symbol: "server.rack")
        }
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
        HStack(spacing: 0) {
          metric("Connections", value: "\(snapshot.connections)")
          Divider().frame(height: 24).padding(.horizontal, 20)
          metric(
            "Received",
            value: snapshot.receivedBytes == 0
              ? "0 B"
              : ByteCountFormatter.string(
                fromByteCount: Int64(clamping: snapshot.receivedBytes), countStyle: .file))
          Spacer(minLength: 0)
        }.padding(.vertical, 2)
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Configuration").font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("Edit…", action: edit).buttonStyle(.borderless).font(.system(size: 12))
          }
          configurationRow("Protocol", value: "TCP")
          configurationRow(
            "Remote address", value: rule.family == .ipv4 ? "IPv4 loopback" : "IPv6 loopback")
          configurationRow("Start on launch", value: rule.autoStart ? "Enabled" : "Disabled")
        }.font(.system(size: 12)).foregroundStyle(.secondary)
        if let error = snapshot.error {
          Label(error, systemImage: "exclamationmark.circle")
            .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
        }
      }.padding(16).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity)
    }
  }

  private func endpoint(_ title: String, address: String, symbol: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Text(verbatim: address).font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.8)
      }
      Spacer(minLength: 0)
    }.padding(.horizontal, 12).padding(.vertical, 10)
  }
  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value).font(.system(size: 16, weight: .medium)).monospacedDigit()
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func configurationRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundStyle(.primary)
    }
  }
}

struct FileWorkspace: View {
  @ObservedObject var model: AppModel
  @ObservedObject var transfers: FileTransferManager
  let server: ServerProfile
  private var records: [FileTransferRecord] {
    transfers.records.filter { $0.serverID == server.id }.reversed()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Send to \(server.name)").font(.system(size: 17, weight: .semibold))
        Text("Drop files or paste an image, then copy its remote path.")
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }.padding(16)
      FileDropView(model: model, transfers: transfers, server: server).padding(.horizontal, 16)
      if records.isEmpty {
        ContentUnavailableView(
          "No transfers yet", systemImage: "doc.on.doc",
          description: Text("Files you send appear here for this session.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(records) { record in
          HStack(spacing: 10) {
            Image(systemName: record.phase == .complete ? "doc" : "arrow.up.doc")
              .foregroundStyle(Palette.accent).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 4) {
              Text(record.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
              Text(verbatim: record.path ?? record.error ?? transferStatus(record))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(
                  .enabled)
            }
            Spacer()
            if record.phase == .complete {
              Button("Copy Path", systemImage: "document.on.document") {
                transfers.copyPath(record)
              }
              .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy remote path")
            } else if record.phase == .uploading || record.phase == .queued {
              Button("Cancel", systemImage: "xmark.circle") { transfers.cancel(record.id) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Cancel upload")
            }
          }.padding(.vertical, 8)
        }.listStyle(.inset).padding(.top, 16)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private func transferStatus(_ record: FileTransferRecord) -> String {
    switch record.phase {
    case .queued: "Queued"
    case .uploading: "Sending… \(Int(record.progress * 100))%"
    case .complete: "Sent"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }
}
