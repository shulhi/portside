import AppKit
import Combine
import Foundation
import PortsideCore
import UniformTypeIdentifiers

enum FileTransferPhase { case queued, uploading, complete, failed, cancelled }

struct FileTransferRecord: Identifiable {
  let id: UUID
  let serverID: UUID
  let name: String
  var phase: FileTransferPhase = .queued
  var progress: Double = 0
  var path: String?
  var error: String?
}

@MainActor
final class FileTransferManager: ObservableObject {
  @Published private(set) var records: [FileTransferRecord] = []
  @Published var message: String?
  private struct Pending {
    let id: UUID
    let server: ServerProfile
    let source: FileUploadSource
  }
  private var pending: [Pending] = []
  private var current: Pending?
  private var worker: Task<Void, Never>?
  private var closing = false
  private var generations: [UUID: UInt64] = [:]

  func enqueue(_ inputs: [FileUploadSource], server: ServerProfile) {
    guard !closing else { return }
    guard !inputs.isEmpty else { return }
    guard inputs.count + pending.count <= 50 else {
      message = "Add up to 50 files at a time."
      return
    }
    do { try server.validate() } catch {
      message = error.localizedDescription
      return
    }
    message = nil
    if records.count > 30 {
      let old = Set(
        records.filter { $0.phase != .queued && $0.phase != .uploading }.prefix(records.count - 30)
          .map(\.id))
      records.removeAll { old.contains($0.id) }
    }
    for input in inputs {
      let id = UUID()
      records.append(FileTransferRecord(id: id, serverID: server.id, name: input.name))
      pending.append(Pending(id: id, server: server, source: input))
    }
    beginWorker()
  }

  func paste(server: ServerProfile) {
    do { enqueue(try ClipboardFiles.read(), server: server) } catch {
      message = error.localizedDescription
    }
  }

  func importProviders(_ providers: [NSItemProvider], server: ServerProfile) {
    let generation = generations[server.id, default: 0]
    guard providers.count <= 50 else {
      message = "Drop up to 50 files at a time."
      return
    }
    Task {
      for provider in providers {
        do {
          if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await Self.fileURL(from: provider)
            guard generations[server.id, default: 0] == generation else { return }
            enqueue([.file(url)], server: server)
          } else if let type = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
          }) {
            let data = try await Self.imageData(from: provider, type: type)
            guard generations[server.id, default: 0] == generation else { return }
            guard let image = NSImage(data: data) else {
              throw PortsideError.invalid("This dropped image could not be read.")
            }
            enqueue([try ClipboardFiles.source(from: image)], server: server)
          }
        } catch { message = error.localizedDescription }
      }
    }
  }

  func chooseFiles(server: ServerProfile) {
    let generation = generations[server.id, default: 0]
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Send files"
    panel.begin { [weak self] response in
      guard response == .OK else { return }
      guard self?.generations[server.id, default: 0] == generation else { return }
      self?.enqueue(panel.urls.map(FileUploadSource.file), server: server)
    }
  }

  func copyPath(_ record: FileTransferRecord) {
    guard let path = record.path else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }

  func cancel(_ id: UUID) {
    pending.removeAll { $0.id == id }
    update(id) { $0.phase = .cancelled }
    if current?.id == id { worker?.cancel() }
  }

  func cancel(serverID: UUID) {
    generations[serverID, default: 0] += 1
    for record in records
    where record.serverID == serverID && (record.phase == .queued || record.phase == .uploading) {
      cancel(record.id)
    }
  }

  func shutdown() {
    closing = true
    pending.removeAll()
    worker?.cancel()
  }

  private func beginWorker() {
    guard worker == nil, !pending.isEmpty, !closing else { return }
    worker = Task { [self] in
      defer {
        current = nil
        worker = nil
        beginWorker()
      }
      while !pending.isEmpty && !Task.isCancelled {
        let item = pending.removeFirst()
        current = item
        update(item.id) { $0.phase = .uploading }
        do {
          let info = try await ServerAPI.info(for: item.server)
          guard let settings = info.uploads else {
            throw PortsideError.invalid("Enable --upload-dir on the server to receive files.")
          }
          let result = try await FileUploadAPI.upload(
            item.source, to: item.server, settings: settings
          ) { [weak self] progress in
            Task { @MainActor in self?.update(item.id) { $0.progress = progress } }
          }
          update(item.id) {
            $0.phase = .complete
            $0.path = result.path
            $0.progress = 1
          }
        } catch {
          if Task.isCancelled {
            update(item.id) { $0.phase = .cancelled }
          } else {
            update(item.id) {
              $0.phase = .failed
              $0.error = error.localizedDescription
            }
          }
        }
        current = nil
      }
    }
  }

  private func update(_ id: UUID, change: (inout FileTransferRecord) -> Void) {
    if let index = records.firstIndex(where: { $0.id == id }) { change(&records[index]) }
  }

  private static func fileURL(from provider: NSItemProvider) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        let url: URL?
        if let value = item as? URL {
          url = value
        } else if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let text = item as? String {
          url = URL(string: text)
        } else {
          url = nil
        }
        guard let url, url.isFileURL else {
          continuation.resume(throwing: PortsideError.invalid("This drop is not a local file."))
          return
        }
        continuation.resume(returning: url)
      }
    }
  }

  private static func imageData(from provider: NSItemProvider, type: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: PortsideError.invalid("This image could not be loaded."))
        }
      }
    }
  }
}
