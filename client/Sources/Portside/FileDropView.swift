import PortsideCore
import SwiftUI
import UniformTypeIdentifiers

struct FileDropView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var transfers: FileTransferManager
  let server: ServerProfile
  @State private var targeted = false
  @State private var showingFolder = false
  @State private var showingHistory = false
  @State private var folder = ""
  @State private var folderError: String?
  @FocusState private var pasteFocused: Bool

  private var settings: UploadSettings? {
    if case .ready(let info) = model.serverStates[server.id] { return info.uploads }
    return nil
  }
  private var records: [FileTransferRecord] {
    transfers.records.filter { $0.serverID == server.id }
  }
  private var latest: FileTransferRecord? {
    records.first { $0.phase == .uploading } ?? records.last
  }
  private var destination: String {
    if let settings {
      return UploadDestination.displayPath(root: settings.directory, folder: server.uploadFolder)
    }
    if case .ready = model.serverStates[server.id] {
      return "Enable --upload-dir on the server to receive files"
    }
    return "Connect to check the server's upload directory"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Image(systemName: "arrow.up.doc").font(.system(size: 16)).foregroundStyle(Palette.accent)
        VStack(alignment: .leading, spacing: 3) {
          Text("Drop files or paste an image").font(.system(size: 11, weight: .medium))
          Text(verbatim: destination).font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).help(Text(verbatim: destination))
        }
        Spacer(minLength: 4)
        Button {
          showingFolder = true
          folder = server.uploadFolder
          folderError = nil
        } label: {
          Image(systemName: "folder.badge.gearshape")
        }.controlSize(.small).foregroundStyle(.secondary).help("Upload destination")
        Button("Paste") { transfers.paste(server: server) }.controlSize(.small)
          .help("Paste an image or copied files. You can also click the drop area and press ⌘V.")
        Button {
          transfers.chooseFiles(server: server)
        } label: {
          Image(systemName: "plus")
        }
        .controlSize(.small).help("Choose files to send")
      }
      if let message = transfers.message {
        Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
      }
      if let record = latest { transferRow(record) }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Palette.accent.opacity(targeted || pasteFocused ? 0.09 : 0.025),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(
        Palette.accent.opacity(targeted || pasteFocused ? 0.65 : 0.25),
        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .focusable().focused($pasteFocused).onTapGesture { pasteFocused = true }
    .onPasteCommand(of: [.fileURL, .image]) { transfers.importProviders($0, server: server) }
    .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
      transfers.importProviders(providers, server: server)
      return !providers.isEmpty
    }
    .popover(isPresented: $showingFolder) { folderEditor }
    .popover(isPresented: $showingHistory) { history }
    .task(id: server.id) { if model.serverStates[server.id] == nil { await model.check(server) } }
  }

  private func transferRow(_ record: FileTransferRecord) -> some View {
    HStack(spacing: 7) {
      if record.phase == .uploading || record.phase == .queued {
        ProgressView(value: record.progress).frame(width: 45)
        Text(record.phase == .queued ? "Queued: \(record.name)" : "Sending \(record.name)…")
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        Button("Cancel") { transfers.cancel(record.id) }.controlSize(.mini)
      } else if record.phase == .complete {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
        Text(verbatim: record.path ?? record.name).lineLimit(1).truncationMode(.middle)
          .help(Text(verbatim: record.path ?? record.name))
        Spacer(minLength: 0)
        Button("Copy path") { transfers.copyPath(record) }.controlSize(.mini)
      } else {
        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        Text(record.phase == .cancelled ? "Upload cancelled" : record.error ?? "Upload failed")
          .lineLimit(2).help(record.error ?? "")
        Spacer(minLength: 0)
      }
      Button {
        showingHistory = true
      } label: {
        Image(systemName: "clock.arrow.circlepath")
      }
      .controlSize(.small).help("Recent uploads")
    }.font(.system(size: 10)).foregroundStyle(.secondary)
  }

  private var folderEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Upload destination").font(.headline)
      Text(verbatim: settings?.directory ?? "Set --upload-dir on the server first.")
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(
          .enabled)
      TextField("Subfolder (optional)", text: $folder).textFieldStyle(.roundedBorder)
      Text(
        "Files stay inside the server's upload directory. Use a subfolder such as project/screenshots."
      )
      .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      if let folderError { Text(folderError).font(.system(size: 11)).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Save") {
          do {
            try model.saveUploadFolder(folder, serverID: server.id)
            showingFolder = false
          } catch { folderError = error.localizedDescription }
        }.buttonStyle(.glassProminent)
      }
    }.padding(18).frame(width: 330).tint(Palette.accent).buttonStyle(.glass)
  }

  private var history: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Recent uploads").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(records.reversed()) { record in
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 4) {
                Text(record.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(
                  verbatim: record.path ?? record.error
                    ?? (record.phase == .cancelled ? "Cancelled" : "Waiting to finish")
                )
                .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
              }
              Spacer()
              Button("Copy path") { transfers.copyPath(record) }.controlSize(.small).disabled(
                record.path == nil)
            }
          }
        }
      }.frame(maxHeight: 230)
    }.padding(18).frame(width: 440).buttonStyle(.glass)
  }
}
