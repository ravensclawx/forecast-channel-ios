import Foundation
import NW4R
import RVL

/// Locates and opens the channel's own title contents, replacing the SDK's CNTOpen / ARCOpen / NAND
/// paths that main.dol uses. Content indices are the TMD indices of HAFE v7.
public final class Assets {
    public enum Content: UInt16 {
        case banner = 0, mainDol = 1, opera = 2, operaRes = 3, icon = 4, bannerArc = 5
        case homeButton = 6, systemFonts = 7, earth = 8, weather = 9, html = 10, extra = 11
    }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ForecastChannel", isDirectory: true)
    }

    public let title: ESTitle
    /// Folder holding HAFE.wad + common-key.bin (and `upscaled/`, see TextureOverrides).
    public let directory: URL

    public init(directory: URL = Assets.supportDirectory) throws {
        self.directory = directory
        let keyURL = directory.appendingPathComponent("common-key.bin")
        let wadURL = directory.appendingPathComponent("HAFE.wad")
        guard let key = try? Data(contentsOf: keyURL), key.count == 16 else {
            throw RVLError.missing("\(keyURL.path) (16-byte Wii common key)")
        }
        guard FileManager.default.fileExists(atPath: wadURL.path) else { throw RVLError.missing(wadURL.path) }
        title = try ESTitle(wadURL: wadURL, commonKey: [UInt8](key))
    }

    public func archive(_ c: Content) throws -> ARCArchive { try title.archive(index: c.rawValue) }

    private var layoutArc: ARCArchive?
    private var fontCache: [String: ResFont] = [:]
    private var tplCache: [String: TPLFile] = [:]

    /// weather_layout.arc.LZ (content 9): /arc/blyt, /arc/timg, /arc/font.
    public func weatherLayoutArchive() throws -> ARCArchive {
        if let a = layoutArc { return a }
        guard let lz = try archive(.weather).find("weather_layout.arc.LZ") else { throw RVLError.missing("weather_layout.arc.LZ") }
        let a = try ARCArchive(CX.uncompressIfNeeded(lz))
        layoutArc = a
        return a
    }

    public func layout(_ name: String) throws -> Layout {
        guard let d = try weatherLayoutArchive().file("/arc/blyt/\(name)") else { throw RVLError.missing(name) }
        return try Layout(d)
    }

    /// Layout texture by txl1 name (looked up in /arc/timg like the lyt ArcResourceAccessor).
    public func layoutTexture(_ name: String) -> TPLFile.Image? {
        if let t = tplCache[name] { return t.images.first }
        guard let d = try? weatherLayoutArchive().file("/arc/timg/\(name)"), let t = try? TPLFile(d) else { return nil }
        tplCache[name] = t
        return t.images.first
    }

    /// Fonts: layout-archive fonts (/arc/font) or the standalone *.brfnt.LZ files in content 9.
    public func font(_ name: String) -> ResFont? {
        if let f = fontCache[name] { return f }
        var data = try? weatherLayoutArchive().file("/arc/font/\(name)")
        if data == nil { data = try? archive(.weather).find(name.hasSuffix(".LZ") ? name : name + ".LZ") }
        guard let d = data, let f = try? ResFont(CX.uncompressIfNeeded(d)) else { return nil }
        fontCache[name] = f
        return f
    }

    private var hbmArcs: [String: ARCArchive] = [:]

    /// HOME Button Menu archives in content 6 ("HomeButton3/LZ77_homeBtn[_ENG].arc", CContentArc).
    public func hbmArchive(_ suffix: String = "_ENG") throws -> ARCArchive {
        if let a = hbmArcs[suffix] { return a }
        guard let lz = try archive(.homeButton).file("/HomeButton3/LZ77_homeBtn\(suffix).arc") else { throw RVLError.missing("homeBtn\(suffix)") }
        let a = try ARCArchive(CX.uncompressIfNeeded(lz))
        hbmArcs[suffix] = a
        return a
    }

    private var sysFont: ResFont??
    /// The console system font wbf1.brfna (nw4r::ut::ArchiveFont), shipped in the title's content 7 alongside
    /// wbf2.brfna (System_Init opens contents 6..11 into CNT slots 4..9; the scene loads slot 5 = content 7).
    public func systemFont() -> ResFont? {
        if let f = sysFont { return f }
        let f = (try? archive(.systemFonts))?.find("wbf1.brfna").flatMap { try? ResFont($0) }
        sysFont = .some(f)
        return f
    }

    /// Equivalent of the channel loading "/earth.brres.LZ" out of content 8 and CXUncompressLZ-ing it.
    public func earthBRRES() throws -> ResFile {
        guard let lz = try archive(.earth).file("/earth.brres.LZ") else { throw RVLError.missing("/earth.brres.LZ") }
        return try ResFile(CX.uncompressIfNeeded(lz))
    }
}
