import SwiftUI
import Darwin
import ServiceManagement

// Samsung Tizen remote: wss://<ip>:8002/api/v2/channels/samsung.remote.control
// First connect shows an "Allow" prompt on the TV; the returned token is saved so it never asks again.
@MainActor
final class TV: NSObject, ObservableObject, URLSessionDelegate {
    @AppStorage("ip") var ip = ""
    @AppStorage("mac") var mac = ""
    @AppStorage("token") var token = ""
    @Published var status = "Disconnected"

    private var task: URLSessionWebSocketTask?
    @Published private(set) var ready = false
    private var pending: [() -> Void] = []
    private var retryUntil = Date.distantPast
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    // Called when the panel opens so the first press doesn't wait for the handshake.
    func warmUp() {
        if !ip.isEmpty, !ready { connect() }
    }

    func send(_ key: String) {
        if key == "KEY_POWER", !ready { wake() }
        whenConnected { self.write(key) }
    }

    // Press/Release lets the TV auto-repeat while a button is held, like the physical remote.
    func hold(_ key: String, _ down: Bool) {
        whenConnected { self.write(key, down ? "Press" : "Release") }
    }

    func launch(_ appId: String) { whenConnected { self.app("POST", appId, done: "Launched") } }

    // Only closes the apps listed in the remote; Device Care has no remote API.
    func cleanup(_ appIds: [String]) {
        whenConnected { appIds.forEach { self.app("DELETE", $0, done: "Closed apps") } }
        send("KEY_HOME")
    }

    // Commands pressed while disconnected run in order once the TV answers.
    // 30s of retries covers a boot from standby after Wake-on-LAN; raise it if your TV is slower.
    private func whenConnected(_ command: @escaping () -> Void) {
        guard !ip.isEmpty else { status = "Set the TV IP in settings"; return }
        if ready { return command() }
        pending.append(command)
        retryUntil = Date().addingTimeInterval(30)
        connect()
    }

    private func app(_ method: String, _ appId: String, done: String) {
        guard let url = URL(string: "http://\(ip):8001/api/v2/applications/\(appId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        URLSession.shared.dataTask(with: req) { [weak self] _, _, err in
            Task { @MainActor in self?.status = err.map { "Error: \($0.localizedDescription)" } ?? done }
        }.resume()
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
            let queued = pending
            pending = []
            queued.forEach { $0() }
        case "ms.channel.unauthorized":
            pending = []
            drop("Denied on TV")
        default: break
        }
    }

    private func write(_ key: String, _ cmd: String = "Click") {
        let msg = #"{"method":"ms.remote.control","params":{"Cmd":"\#(cmd)","DataOfCmd":"\#(key)","Option":"false","TypeOfRemote":"SendRemoteKey"}}"#
        task?.send(.string(msg)) { [weak self] err in
            guard let err, let self else { return }
            Task { @MainActor in
                // Connection went stale (e.g. TV slept); requeue so the key isn't lost.
                self.pending.append { self.write(key, cmd) }
                self.retryUntil = Date().addingTimeInterval(30)
                self.drop("Error: \(err.localizedDescription)")
            }
        }
    }

    private func drop(_ msg: String) {
        task?.cancel()
        task = nil
        ready = false
        if !pending.isEmpty, Date() < retryUntil {
            status = "Waiting for TV… (\(pending.count) queued)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
        } else {
            pending = []
            status = msg
        }
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
    var repeats = false
    @State private var held = false

    var body: some View {
        let b = Button {
            // Mouse holds already sent Press/Release; keyboard shortcuts and plain keys land here.
            if !held { tv.send(key) }
            held = false
        } label: {
            Image(systemName: symbol).font(.title3).frame(width: 44, height: 36)
        }
        .buttonStyle(KeyStyle(tint: tint) { down in
            guard repeats else { return }
            if down { held = true }
            tv.hold(key, down)
        })
        .help(key)
        if let shortcut { b.keyboardShortcut(shortcut, modifiers: []) } else { b }
    }
}

struct KeyStyle: ButtonStyle {
    let tint: Color
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.25 : 0.1)))
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, down in onPress(down) }
    }
}

struct RemoteView: View {
    @EnvironmentObject var tv: TV
    @State private var showSettings = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    // App IDs checked against this TV via GET :8001/api/v2/applications/<id>.
    static let shortcuts: [(name: String, icon: String, app: String?, key: String?)] = [
        ("Xbox", "xbox", nil, "KEY_HDMI2"),
        ("Switch", "switch", nil, "KEY_HDMI1"),
        ("Netflix", "netflix", "3201907018807", nil),
        ("YouTube", "youtube", "111299001912", nil),
        ("Stremio", "stremio", "3202306031311", nil),
        ("Spotify", "spotify", "3201606009684", nil),
    ]

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
            Key(symbol: "chevron.up", key: "KEY_UP", shortcut: .upArrow, repeats: true)
            HStack {
                Key(symbol: "chevron.left", key: "KEY_LEFT", shortcut: .leftArrow, repeats: true)
                Key(symbol: "circle.fill", key: "KEY_ENTER", shortcut: .return)
                Key(symbol: "chevron.right", key: "KEY_RIGHT", shortcut: .rightArrow, repeats: true)
            }
            Key(symbol: "chevron.down", key: "KEY_DOWN", shortcut: .downArrow, repeats: true)
            HStack {
                Key(symbol: "arrow.uturn.backward", key: "KEY_RETURN", shortcut: .delete)
                Key(symbol: "xmark", key: "KEY_EXIT", shortcut: .escape)
            }
            Divider()
            HStack(spacing: 20) {
                VStack {
                    Key(symbol: "speaker.plus", key: "KEY_VOLUP", shortcut: "=", repeats: true)
                    Key(symbol: "speaker.slash", key: "KEY_MUTE", shortcut: "0")
                    Key(symbol: "speaker.minus", key: "KEY_VOLDOWN", shortcut: "-", repeats: true)
                }
                VStack {
                    Key(symbol: "chevron.up.2", key: "KEY_CHUP", repeats: true)
                    Text("CH").font(.caption).frame(height: 36)
                    Key(symbol: "chevron.down.2", key: "KEY_CHDOWN", repeats: true)
                }
            }
            HStack {
                Key(symbol: "backward.fill", key: "KEY_REWIND")
                Key(symbol: "playpause.fill", key: "KEY_PLAY", shortcut: " ")
                Key(symbol: "forward.fill", key: "KEY_FF")
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 4), spacing: 8) {
                ForEach(Self.shortcuts, id: \.name) { s in
                    Button { s.app.map(tv.launch) ?? tv.send(s.key!) } label: {
                        Image(nsImage: Bundle.main.image(forResource: s.icon) ?? NSImage())
                            .resizable().frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).help(s.name)
                }
                Button { tv.cleanup(Self.shortcuts.compactMap(\.app)) } label: {
                    Image(systemName: "sparkles").font(.title3).frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered).help("Close all apps")
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
                            Toggle("Open at login", isOn: $openAtLogin)
                                .onChange(of: openAtLogin) { _, on in
                                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                                }
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in tv.warmUp() }
    }
}

@main
struct TVRemoteApp: App {
    @StateObject private var tv = TV()
    var body: some Scene {
        MenuBarExtra {
            RemoteView().environmentObject(tv)
        } label: {
            Image(systemName: tv.ready ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)
    }
}
