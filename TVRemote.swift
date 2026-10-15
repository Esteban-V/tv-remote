import SwiftUI
import Darwin

// Samsung Tizen remote: wss://<ip>:8002/api/v2/channels/samsung.remote.control
// First connect shows an "Allow" prompt on the TV; the returned token is saved so it never asks again.
@MainActor
final class TV: NSObject, ObservableObject, URLSessionDelegate {
    @AppStorage("ip") var ip = ""
    @AppStorage("mac") var mac = ""
    @AppStorage("token") var token = ""
    @Published var status = "Disconnected"

    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var pending: [String] = []
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func send(_ key: String) {
        if key == "KEY_POWER", !ready { wake() }
        guard !ip.isEmpty else { status = "Set the TV IP below"; return }
        if ready { write(key) } else { pending.append(key); connect() }
    }

    private func connect() {
        guard task == nil else { return }
        let name = Data("Mac Remote".utf8).base64EncodedString()
        var s = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        if !token.isEmpty { s += "&token=\(token)" }
        guard let url = URL(string: s) else { status = "Bad IP"; return }
        status = "Connecting… (accept on TV if asked)"
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let e): self.drop("Error: \(e.localizedDescription)")
                case .success(.string(let text)): self.handle(text); self.receive()
                case .success: self.receive()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = json["event"] as? String else { return }
        switch event {
        case "ms.channel.connect":
            if let t = (json["data"] as? [String: Any])?["token"] as? String { token = t }
            ready = true
            status = "Connected"
            pending.forEach(write)
            pending = []
        case "ms.channel.unauthorized":
            drop("Denied on TV")
        default: break
        }
    }

    private func write(_ key: String) {
        let msg = #"{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"\#(key)","Option":"false","TypeOfRemote":"SendRemoteKey"}}"#
        task?.send(.string(msg)) { [weak self] err in
            if let err { Task { @MainActor in self?.drop("Error: \(err.localizedDescription)") } }
        }
    }

    private func drop(_ msg: String) {
        task?.cancel()
        task = nil
        ready = false
        pending = []
        status = msg
    }

    // Wake-on-LAN magic packet; needs "Power On with Mobile" enabled on the TV.
    private func wake() {
        let bytes = mac.split(whereSeparator: { ":-".contains($0) }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        let packet = [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in bytes }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        status = "Sent wake packet…"
    }

    // TV uses a self-signed cert on the LAN.
    nonisolated func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = c.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.performDefaultHandling, nil) }
    }
}

struct Key: View {
    @EnvironmentObject var tv: TV
    let symbol: String, key: String
    var shortcut: KeyEquivalent? = nil
    var tint: Color = .primary

    var body: some View {
        let b = Button { tv.send(key) } label: {
            Image(systemName: symbol).font(.title3).frame(width: 44, height: 36)
        }
        .buttonStyle(.bordered).tint(tint).help(key)
        if let shortcut { b.keyboardShortcut(shortcut, modifiers: []) } else { b }
    }
}

struct RemoteView: View {
    @EnvironmentObject var tv: TV
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Key(symbol: "power", key: "KEY_POWER", tint: .red)
                Spacer()
                Key(symbol: "rectangle.on.rectangle", key: "KEY_SOURCE")
            }
            HStack {
                Key(symbol: "house", key: "KEY_HOME", shortcut: "h")
                Key(symbol: "line.3.horizontal", key: "KEY_MENU", shortcut: "m")
                Key(symbol: "info.circle", key: "KEY_INFO")
            }
            Divider()
            Key(symbol: "chevron.up", key: "KEY_UP", shortcut: .upArrow)
            HStack {
                Key(symbol: "chevron.left", key: "KEY_LEFT", shortcut: .leftArrow)
                Key(symbol: "circle.fill", key: "KEY_ENTER", shortcut: .return)
                Key(symbol: "chevron.right", key: "KEY_RIGHT", shortcut: .rightArrow)
            }
            Key(symbol: "chevron.down", key: "KEY_DOWN", shortcut: .downArrow)
            HStack {
                Key(symbol: "arrow.uturn.backward", key: "KEY_RETURN", shortcut: .delete)
                Key(symbol: "xmark", key: "KEY_EXIT", shortcut: .escape)
            }
            Divider()
            HStack(spacing: 20) {
                VStack {
                    Key(symbol: "speaker.plus", key: "KEY_VOLUP", shortcut: "=")
                    Key(symbol: "speaker.slash", key: "KEY_MUTE", shortcut: "0")
                    Key(symbol: "speaker.minus", key: "KEY_VOLDOWN", shortcut: "-")
                }
                VStack {
                    Key(symbol: "chevron.up.2", key: "KEY_CHUP")
                    Text("CH").font(.caption).frame(height: 36)
                    Key(symbol: "chevron.down.2", key: "KEY_CHDOWN")
                }
            }
            HStack {
                Key(symbol: "backward.fill", key: "KEY_REWIND")
                Key(symbol: "playpause.fill", key: "KEY_PLAY", shortcut: " ")
                Key(symbol: "forward.fill", key: "KEY_FF")
            }
            Divider()
            HStack {
                Text(tv.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        VStack(alignment: .leading) {
                            TextField("TV IP (e.g. 192.168.1.50)", text: $tv.ip)
                            TextField("TV MAC for power-on (optional)", text: $tv.mac)
                            Button("Quit TV Remote") { NSApp.terminate(nil) }
                        }
                        .textFieldStyle(.roundedBorder)
                        .padding()
                        .frame(width: 240)
                    }
            }
        }
        .padding()
        .frame(width: 240)
    }
}

@main
struct TVRemoteApp: App {
    @StateObject private var tv = TV()
    var body: some Scene {
        MenuBarExtra("TV Remote", systemImage: "tv") {
            RemoteView().environmentObject(tv)
        }
        .menuBarExtraStyle(.window)
    }
}
