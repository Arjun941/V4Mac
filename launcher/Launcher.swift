// muguet - Launcher.swift
// Constantin Clerc (c22dev) - 0.1

import AppKit
import SwiftUI
import UniformTypeIdentifiers

let supportURL: URL = {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let new = base.appendingPathComponent("V4Mac"), old = base.appendingPathComponent("Muguet")
    // Carry an existing install over from the pre-rename "Muguet" folder.
    if !FileManager.default.fileExists(atPath: new.path), FileManager.default.fileExists(atPath: old.path) {
        if (try? FileManager.default.moveItem(at: old, to: new)) != nil {
            try? FileManager.default.createSymbolicLink(at: old, withDestinationURL: new) // keep older builds working
        }
    }
    return new
}()
let configURL = supportURL.appendingPathComponent("config.json")
let gameURL = supportURL.appendingPathComponent("game")
let gameBinary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/v4mac")

let savesRoot = supportURL.appendingPathComponent("saves")
let defaultTitle = "GTA V"

func saveSlot(of name: String) -> Int? {
    guard name.hasPrefix("SGTA5") else { return nil }
    let digits = name.dropFirst(5)
    guard digits.count == 4, digits.allSatisfy(\.isNumber) else { return nil }
    return Int(digits)
}

func gameReady() -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: gameURL.appendingPathComponent("data/manifest.json").path),
          let builds = try? fm.contentsOfDirectory(at: gameURL.appendingPathComponent("b"), includingPropertiesForKeys: nil) else { return false }
    let embedded = Bundle.main.object(forInfoDictionaryKey: "V4MacEmbeddedCode") as? Bool ?? false
    return builds.contains { (embedded || fm.fileExists(atPath: $0.appendingPathComponent("game.wasm").path)) && fm.fileExists(atPath: $0.appendingPathComponent("shaders/index.json").path) }
}

final class Importer: ObservableObject {
    @Published var ready = gameReady()
    @Published var progress: Double?
    @Published var error: String?

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose your game data .zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(url)
    }

    func run(_ zip: URL) {
        error = nil
        progress = 0
        let p = Process()
        p.executableURL = gameBinary
        p.arguments = ["--import", zip.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            guard let text = String(data: h.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ")
                if f.count == 3, f[0] == "progress", let d = Double(f[1]), let t = Double(f[2]), t > 0 {
                    DispatchQueue.main.async { self.progress = d / t }
                }
            }
        }
        p.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.progress = nil
                self.ready = gameReady()
                if p.terminationStatus != 0 || !self.ready {
                    self.error = "Import failed: " + (message.split(separator: "\n").last.map(String.init) ?? "unknown error")
                }
            }
        }
        do { try p.run() } catch { progress = nil; self.error = "Could not start the import: \(error.localizedDescription)" }
    }
}

final class Compiler: ObservableObject {
    @Published var started: Date?
    @Published var error: String?
    var expected: Double {
        let s = UserDefaults.standard.double(forKey: "compileSeconds")
        return s > 0 ? s : 60
    }

    func run(then done: @escaping () -> Void) {
        error = nil
        let p = Process()
        p.executableURL = gameBinary
        p.arguments = ["--compile"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            guard let text = String(data: h.availableData, encoding: .utf8), text.contains("compiling") else { return }
            DispatchQueue.main.async { self.started = Date() }
        }
        p.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if let s = self.started, p.terminationStatus == 0 {
                    UserDefaults.standard.set(Date().timeIntervalSince(s), forKey: "compileSeconds")
                }
                self.started = nil
                if p.terminationStatus == 0 { done() } else { self.error = "Compiling the game failed (see ~/Library/Logs/V4Mac.log)" }
            }
        }
        do { try p.run() } catch { self.error = "Could not compile the game: \(error.localizedDescription)" }
    }
}

enum Preset: String, CaseIterable {
    case performance, balanced, quality, max, custom

    var title: String { ["Performance", "Balanced", "Quality", "Max", "Custom"][Preset.allCases.firstIndex(of: self)!] }
    var values: (scale: Double, textures: Int, fps: Int)? {
        switch self {
        case .performance: return (0.5, 0, 60)
        case .balanced: return (0.75, 1, 60)
        case .quality: return (1.0, 2, 60)
        case .max: return (1.0, 2, 0)
        case .custom: return nil
        }
    }
    var summary: String {
        guard let v = values else { return "" }
        return "\(Int(v.scale * 100)) % resolution · \(["Normal", "High", "Very High"][v.textures]) textures · \(v.fps == 0 ? "uncapped" : "\(v.fps)") fps"
    }
}

final class SaveImporter: ObservableObject {
    @Published var status: String?
    @Published var statusIsError = false

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your GTA V save (SGTA5xxxx)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSave(url)
    }

    func importSave(_ source: URL) {
        let fm = FileManager.default
        let name = source.lastPathComponent
        statusIsError = false
        guard saveSlot(of: name) != nil else { return fail("That doesn't look like a save file (SGTA5xxxx).") }

        let dir = savesRoot
            .appendingPathComponent("userdata/Documents/Rockstar Games")
            .appendingPathComponent(defaultTitle)
            .appendingPathComponent("Default")
        let dest = dir.appendingPathComponent(name)
        if source.standardizedFileURL == dest.standardizedFileURL {
            return fail("That file is already the active save.")
        }
        var backup: URL?
        var installed = false
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                let b = backupURL(for: dest, title: defaultTitle)
                try fm.copyItem(at: dest, to: b)
                backup = b
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)
            installed = true
            let slot = saveSlot(of: name) ?? 0
            status = "Imported \(name)."
                + (backup == nil ? "" : " Previous save backed up.")
                + (newerSlotNotice(in: dir, than: slot) ?? "")
        } catch {
            if !installed {
                try? fm.removeItem(at: dest)
                if let b = backup { try? fm.copyItem(at: b, to: dest) }
            }
            fail("Could not import save: \(error.localizedDescription)")
        }
    }

    private func newerSlotNotice(in dir: URL, than slot: Int) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let newest = names.compactMap({ saveSlot(of: $0) }).filter({ $0 > slot }).max() else { return nil }
        return " SGTA5\(String(format: "%04d", newest)) is newer and will be loaded instead."
    }

    private func fail(_ message: String) {
        status = message
        statusIsError = true
    }

    private func backupURL(for dest: URL, title: String) -> URL {
        let dir = savesRoot.appendingPathComponent("save-backups").appendingPathComponent(title)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(dest.lastPathComponent).\(stamp)"
        var url = dir.appendingPathComponent("\(name).bak")
        if FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(4)).bak")
        }
        return url
    }
}


let gtaGreen = Color(red: 0.36, green: 0.69, blue: 0.30)

/// Los Santos sunset: sky, sun, skyline and palms drawn in code. To use your own picture instead,
/// save it as ~/Library/Application Support/V4Mac/launcher-background.jpg (or .png).
struct LosSantosBackdrop: View {
    static let custom: NSImage? = Bundle.main.url(forResource: "launcher-bg", withExtension: "jpg").flatMap { NSImage(contentsOf: $0) } ?? ["jpg", "png"].lazy.compactMap { NSImage(contentsOf: supportURL.appendingPathComponent("launcher-background.\($0)")) }.first

    var body: some View {
        if let img = Self.custom {
            Image(nsImage: img).resizable().scaledToFill().frame(width: 1080, height: 690, alignment: .trailing).clipped()
        } else {
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let sky = Gradient(stops: [
                    .init(color: Color(red: 0.10, green: 0.07, blue: 0.25), location: 0),
                    .init(color: Color(red: 0.55, green: 0.17, blue: 0.42), location: 0.38),
                    .init(color: Color(red: 0.98, green: 0.45, blue: 0.25), location: 0.66),
                    .init(color: Color(red: 1.0, green: 0.78, blue: 0.40), location: 0.86)])
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                let sun = CGRect(x: w * 0.62 - 70, y: h * 0.62 - 70, width: 140, height: 140)
                ctx.fill(Path(ellipseIn: sun.insetBy(dx: -50, dy: -50)), with: .color(Color(red: 1, green: 0.7, blue: 0.4).opacity(0.18)))
                ctx.fill(Path(ellipseIn: sun.insetBy(dx: -22, dy: -22)), with: .color(Color(red: 1, green: 0.75, blue: 0.45).opacity(0.28)))
                ctx.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.93, blue: 0.7)))
                var seed: UInt64 = 7
                func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
                func skyline(base: CGFloat, minH: CGFloat, maxH: CGFloat, color: Color) {
                    var x: CGFloat = -10
                    while x < w {
                        let bw = 14 + rnd() * 28, bh = minH + rnd() * (maxH - minH)
                        ctx.fill(Path(CGRect(x: x, y: base - bh, width: bw, height: bh + 200)), with: .color(color))
                        x += bw + rnd() * 3
                    }
                }
                skyline(base: h * 0.86, minH: 28, maxH: 80, color: Color(red: 0.30, green: 0.12, blue: 0.30))
                skyline(base: h * 0.92, minH: 30, maxH: 110, color: Color(red: 0.16, green: 0.07, blue: 0.20))
                // Maze Bank style tower
                let tx = w * 0.30
                ctx.fill(Path(CGRect(x: tx, y: h * 0.40, width: 30, height: h)), with: .color(Color(red: 0.12, green: 0.05, blue: 0.16)))
                ctx.fill(Path(CGRect(x: tx + 13, y: h * 0.40 - 22, width: 4, height: 22)), with: .color(Color(red: 0.12, green: 0.05, blue: 0.16)))
                // palms
                func palm(_ x: CGFloat, _ height: CGFloat, lean: CGFloat) {
                    let base = CGPoint(x: x, y: h), top = CGPoint(x: x + lean, y: h - height)
                    var trunk = Path(); trunk.move(to: base)
                    trunk.addQuadCurve(to: top, control: CGPoint(x: x + lean * 0.1, y: h - height * 0.55))
                    ctx.stroke(trunk, with: .color(.black), lineWidth: 5)
                    for k in 0..<9 {
                        let a = Double(k) / 9 * .pi * 2 + 0.3, len: CGFloat = 52
                        var f = Path(); f.move(to: top)
                        let end = CGPoint(x: top.x + cos(a) * len, y: top.y + sin(a) * len * 0.55 + 14)
                        f.addQuadCurve(to: end, control: CGPoint(x: top.x + cos(a) * len * 0.6, y: top.y + sin(a) * len * 0.5 - 16))
                        ctx.stroke(f, with: .color(.black), lineWidth: 3)
                    }
                }
                palm(w * 0.06, 230, lean: 26)
                palm(w * 0.16, 170, lean: 14)
                palm(w * 0.90, 250, lean: -28)
                palm(w * 0.80, 180, lean: -12)
            }
        }
    }
}

final class Settings: ObservableObject {
    @Published var preset = Preset.balanced
    @Published var mode = 2
    @Published var scale = 0.5
    @Published var textures = 0
    @Published var fullscreen = true
    @Published var fps = 60
    @Published var mouse = 2.0
    @Published var mute = false
    @Published var modMenu = true
    @Published var multiplayer = false
    @Published var host = true
    @Published var server = ""
    @Published var name = NSUserName()
    var extra: [String: Any] = [:]

    init() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        extra = json
        if let v = json["graphics_preset"] as? String, let p = Preset(rawValue: v) { preset = p }
        else if json["texture_quality"] != nil || (json["scale"] as? Double).map({ $0 != 0.5 }) == true { preset = .custom }
        if let v = json["start_mode"] as? Int, (1...2).contains(v) { mode = v }
        if let v = json["scale"] as? Double { scale = v }
        if let v = json["texture_quality"] as? Int, (0...2).contains(v) { textures = v }
        if let v = json["fullscreen"] as? Bool { fullscreen = v }
        if let v = json["fps_limit"] as? Int { fps = v }
        if let v = json["mouse_sensitivity"] as? Double { mouse = v }
        if let v = json["mute"] as? Bool { mute = v }
        if let v = json["mod_menu"] as? Bool { modMenu = v }
        if let v = json["multiplayer"] as? Bool { multiplayer = v }
        if let v = json["host"] as? Bool { host = v }
        if let v = json["server"] as? String { server = v }
        if let v = json["player_name"] as? String, !v.isEmpty { name = v }
    }

    func save() throws {
        var json = extra
        if let v = preset.values { (scale, textures, fps) = v }
        json["graphics_preset"] = preset.rawValue
        json["start_mode"] = mode
        json["scale"] = scale
        json["texture_quality"] = textures
        json["fullscreen"] = fullscreen
        json["fps_limit"] = fps
        json["mouse_sensitivity"] = (mouse * 10).rounded() / 10
        json["mute"] = mute
        json["mod_menu"] = modMenu
        json["multiplayer"] = multiplayer
        json["host"] = host
        json["server"] = server.trimmingCharacters(in: .whitespaces)
        json["player_name"] = name.trimmingCharacters(in: .whitespaces)
        if json["extra_args"] == nil { json["extra_args"] = [String]() }
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL)
    }
}

let accent = Color(red: 0.99, green: 0.69, blue: 0.09)
let night = Color(red: 0.03, green: 0.03, blue: 0.04)
let modsURL = supportURL.appendingPathComponent("mods")

func display(_ size: CGFloat) -> Font { .custom("Futura-CondensedExtraBold", size: size) }

extension View {
    /// Flat dark panel with a thin edge: sharp, like the Rockstar launcher.
    func glass(_ radius: CGFloat = 2) -> some View {
        background(Rectangle().fill(Color.black.opacity(0.66)))
            .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
    }
}

struct ModeCard: View {
    let title: String, symbol: String, subtitle: String, selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().fill(selected ? accent : .clear).frame(height: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(selected ? accent : .white.opacity(0.55))
                    Text(title.uppercased()).font(display(19)).tracking(1.5).foregroundStyle(selected ? .white : .white.opacity(0.7))
                    Text(subtitle.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()
            .overlay(Rectangle().stroke(selected ? accent : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct LauncherView: View {
    @StateObject private var s = Settings()
    @StateObject private var importer = Importer()
    @StateObject private var compiler = Compiler()
    @StateObject private var save = SaveImporter()
    @State private var error: String?
    @State private var showMultiplayer = false
    @State private var modCount = 0

    var body: some View {
        ZStack(alignment: .leading) {
            LosSantosBackdrop().frame(width: 1080, height: 690).clipped()
            LinearGradient(stops: [.init(color: night.opacity(0.80), location: 0), .init(color: night.opacity(0.62), location: 0.30), .init(color: night.opacity(0.28), location: 0.55), .init(color: night.opacity(0.06), location: 0.80), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, night.opacity(0.35)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 16) {
                header
                if !importer.ready || importer.progress != nil {
                    importView
                } else if let started = compiler.started {
                    compileView(started)
                } else {
                    settingsView
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MADE BY OFFSPACE").font(.system(size: 9, weight: .bold)).tracking(1.5)
                    Text("Based on Muguet by c22dev · github.com/c22dev/muguet").font(.system(size: 9))
                    Text("Unofficial fan project · plays your own game files").font(.system(size: 9))
                }
                .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 30).padding(.vertical, 22)
            .frame(width: 450)
            logoView
            VStack { Spacer(); statusChips }.frame(maxWidth: .infinity, alignment: .trailing).padding(26)
        }
        .frame(width: 1080, height: 690)
        .background(night)
        .preferredColorScheme(.dark)
        .tint(accent)
        .onAppear { DispatchQueue.main.async { NSApp.windows.first { $0.isVisible }?.center() } }
        .onAppear { modCount = ((try? FileManager.default.contentsOfDirectory(atPath: modsURL.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "README.txt" }.count }
    }

    var header: some View {
        HStack(spacing: 10) {
            Text("MACOS EDITION").font(display(13)).tracking(4).foregroundStyle(accent)
            Rectangle().fill(.white.opacity(0.25)).frame(height: 1)
        }
        .padding(.top, 4)
    }

    /// The game logo, centred in the right half of the window.
    var logoView: some View {
        Group {
            if let url = Bundle.main.url(forResource: "v4mac-logo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
                Image(nsImage: logo).resizable().scaledToFit().frame(height: 300)
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 6)
            } else {
                Text("GRAND THEFT AUTO V").font(display(40)).foregroundStyle(.white)
            }
        }
        .frame(width: 540, height: 690)
        .offset(x: 540)
    }

    var statusChips: some View {
        HStack(spacing: 8) {
            chip(importer.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", importer.ready ? "Game files ready" : "Game files missing", importer.ready ? accent : .orange)
            Button {
                try? FileManager.default.createDirectory(at: modsURL, withIntermediateDirectories: true)
                NSWorkspace.shared.open(modsURL)
            } label: { chip("folder.fill", modCount == 0 ? "Open mods folder" : "Mods: \(modCount) · open folder", .white) }
                .buttonStyle(.plain)
        }
    }

    func chip(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).glass()
    }

    @ViewBuilder var importView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD YOUR GAME").font(display(22)).tracking(2)
            Text("Choose the .zip that holds your game's data/ and b/<build>/ folders.").font(.callout).foregroundStyle(.white.opacity(0.65))
            if let p = importer.progress {
                ProgressView(value: p).tint(accent)
                Text("Importing… \(Int(p * 100)) %").font(.callout).monospacedDigit()
            } else {
                primaryButton("IMPORT GAME DATA") { importer.choose() }
            }
            if let e = importer.error { Text(e).foregroundStyle(.red).font(.callout) }
        }
        .padding(18).glass()
    }

    func compileView(_ started: Date) -> some View {
        TimelineView(.periodic(from: started, by: 0.5)) { t in
            let elapsed = t.date.timeIntervalSince(started)
            VStack(alignment: .leading, spacing: 12) {
                Text("GETTING READY").font(display(22)).tracking(2)
                ProgressView(value: min(elapsed / compiler.expected, 0.95)).tint(accent)
                Text("Compiling the game for this Mac… \(Int(elapsed)) s").font(.callout).monospacedDigit()
                Text("First launch only, about a minute.").font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .padding(18).glass()
        }
    }

    func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(display(24)).tracking(5).foregroundStyle(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(Rectangle().fill(accent))
        }
        .buttonStyle(.plain)
    }

    func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack { Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.85)); Spacer(); content() }
            .padding(.horizontal, 14).padding(.vertical, 9)
    }
    var rule: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }

    @ViewBuilder var settingsView: some View {
        HStack(spacing: 10) {
            ModeCard(title: "Story Mode", symbol: "book.fill", subtitle: "Play the campaign", selected: s.mode == 1) { s.mode = 1 }
            ModeCard(title: "Sandbox", symbol: "map.fill", subtitle: "Free roam", selected: s.mode == 2) { s.mode = 2 }
        }
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                row("Graphics") {
                    Picker("", selection: $s.preset) { ForEach(Preset.allCases, id: \.self) { p in Text(p.title).tag(p) } }
                        .labelsHidden().frame(width: 150)
                }
                if s.preset != .custom {
                    Text(s.preset.summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
                } else {
                    rule
                    row("Resolution") { Picker("", selection: $s.scale) { Text("50 %").tag(0.5); Text("75 %").tag(0.75); Text("100 %").tag(1.0) }.labelsHidden().frame(width: 150) }
                    rule
                    row("Textures") { Picker("", selection: $s.textures) { Text("Normal").tag(0); Text("High").tag(1); Text("Very High").tag(2) }.labelsHidden().frame(width: 150) }
                    rule
                    row("Frame limit") { Picker("", selection: $s.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60); Text("Uncapped").tag(0) }.labelsHidden().frame(width: 150) }
                }
                rule
                row("Mouse sensitivity") {
                    Slider(value: $s.mouse, in: 0.5...6, step: 0.5).frame(width: 120)
                    Text(String(format: "%.1f×", s.mouse)).monospacedDigit().font(.system(size: 12)).frame(width: 36, alignment: .trailing)
                }
                rule
                row("Fullscreen") { Toggle("", isOn: $s.fullscreen).labelsHidden().toggleStyle(.switch) }
                rule
                row("Mute audio") { Toggle("", isOn: $s.mute).labelsHidden().toggleStyle(.switch) }
                rule
                row("Mod menu  (press ` in game)") { Toggle("", isOn: $s.modMenu).labelsHidden().toggleStyle(.switch) }
                rule
                row("Multiplayer") { Toggle("", isOn: $s.multiplayer).labelsHidden().toggleStyle(.switch) }
                if s.multiplayer {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Your name", text: $s.name)
                        Picker("", selection: $s.host) { Text("Host").tag(true); Text("Join").tag(false) }.pickerStyle(.segmented).labelsHidden()
                        if s.host {
                            Text("Friends join with: \(localIPs().joined(separator: " or "))").font(.system(size: 11)).textSelection(.enabled)
                            Text("Over the internet, forward UDP port 47520 to this Mac.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        } else {
                            TextField("Host address", text: $s.server, prompt: Text("192.168.1.20"))
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }
                rule
                saveView.padding(.horizontal, 14).padding(.vertical, 9)
            }
        }
        .glass()
        .frame(height: 335)
        if let error = error ?? compiler.error { Text(error).foregroundStyle(.red).font(.callout) }
        primaryButton("PLAY", action: play).keyboardShortcut(.defaultAction)
        HStack {
            Text("Cmd+F fullscreen · Cmd+any key frees the mouse · Cmd+Q quits").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("IMPORT OTHER GAME DATA…") { importer.choose() }.buttonStyle(.plain).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(accent)
        }
    }

    @ViewBuilder var saveView: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Import save…") { save.choose() }
                    if let st = save.status {
                        Text(st).font(.caption).foregroundStyle(save.statusIsError ? Color.red : Color.white.opacity(0.55))
                    }
                }
                Text("Your current save is kept in the saves/save-backups folder.").font(.caption).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.top, 4)
        } label: {
            Text("LOAD CUSTOM SAVE").font(.system(size: 11, weight: .bold)).tracking(1.2)
        }
    }

    func play() {
        if s.multiplayer && !s.host && s.server.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "Enter the host's address to join."
            return
        }
        do { try s.save() } catch { self.error = "Could not save settings: \(error.localizedDescription)"; return }
        error = nil
        compiler.run(then: launch)
    }

    func launch() {
        let game = gameBinary.path
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(game), nil]
        execv(game, &argv)
        error = "Could not start the game (\(String(cString: strerror(errno))))"
    }
}

func localIPs() -> [String] {
    var out: [String] = []
    var ifs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifs) == 0, let first = ifs else { return ["?"] }
    defer { freeifaddrs(ifs) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") && !out.contains(ip) { out.append(ip) }
        }
    }
    return out.isEmpty ? ["?"] : out
}

@main
struct V4MacLauncher: App {
    var body: some Scene {
        WindowGroup("V4Mac") { LauncherView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
