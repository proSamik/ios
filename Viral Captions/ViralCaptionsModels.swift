import Foundation
import CoreGraphics
import UniformTypeIdentifiers

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String

    static let all: [LanguageOption] = [
        .init(id: "auto", name: "Auto-detect"),
        .init(id: "af", name: "Afrikaans"),
        .init(id: "am", name: "Amharic"),
        .init(id: "ar", name: "Arabic"),
        .init(id: "as", name: "Assamese"),
        .init(id: "az", name: "Azerbaijani"),
        .init(id: "ba", name: "Bashkir"),
        .init(id: "be", name: "Belarusian"),
        .init(id: "bg", name: "Bulgarian"),
        .init(id: "bn", name: "Bengali"),
        .init(id: "bo", name: "Tibetan"),
        .init(id: "br", name: "Breton"),
        .init(id: "bs", name: "Bosnian"),
        .init(id: "ca", name: "Catalan"),
        .init(id: "cs", name: "Czech"),
        .init(id: "cy", name: "Welsh"),
        .init(id: "da", name: "Danish"),
        .init(id: "de", name: "German"),
        .init(id: "el", name: "Greek"),
        .init(id: "en", name: "English"),
        .init(id: "es", name: "Spanish"),
        .init(id: "et", name: "Estonian"),
        .init(id: "eu", name: "Basque"),
        .init(id: "fa", name: "Persian"),
        .init(id: "fi", name: "Finnish"),
        .init(id: "fo", name: "Faroese"),
        .init(id: "fr", name: "French"),
        .init(id: "gl", name: "Galician"),
        .init(id: "gu", name: "Gujarati"),
        .init(id: "ha", name: "Hausa"),
        .init(id: "haw", name: "Hawaiian"),
        .init(id: "he", name: "Hebrew"),
        .init(id: "hi", name: "Hindi"),
        .init(id: "hr", name: "Croatian"),
        .init(id: "ht", name: "Haitian Creole"),
        .init(id: "hu", name: "Hungarian"),
        .init(id: "hy", name: "Armenian"),
        .init(id: "id", name: "Indonesian"),
        .init(id: "is", name: "Icelandic"),
        .init(id: "it", name: "Italian"),
        .init(id: "ja", name: "Japanese"),
        .init(id: "jw", name: "Javanese"),
        .init(id: "ka", name: "Georgian"),
        .init(id: "kk", name: "Kazakh"),
        .init(id: "km", name: "Khmer"),
        .init(id: "kn", name: "Kannada"),
        .init(id: "ko", name: "Korean"),
        .init(id: "la", name: "Latin"),
        .init(id: "lb", name: "Luxembourgish"),
        .init(id: "ln", name: "Lingala"),
        .init(id: "lo", name: "Lao"),
        .init(id: "lt", name: "Lithuanian"),
        .init(id: "lv", name: "Latvian"),
        .init(id: "mg", name: "Malagasy"),
        .init(id: "mi", name: "Maori"),
        .init(id: "mk", name: "Macedonian"),
        .init(id: "ml", name: "Malayalam"),
        .init(id: "mn", name: "Mongolian"),
        .init(id: "mr", name: "Marathi"),
        .init(id: "ms", name: "Malay"),
        .init(id: "mt", name: "Maltese"),
        .init(id: "my", name: "Myanmar"),
        .init(id: "ne", name: "Nepali"),
        .init(id: "nl", name: "Dutch"),
        .init(id: "nn", name: "Nynorsk"),
        .init(id: "no", name: "Norwegian"),
        .init(id: "oc", name: "Occitan"),
        .init(id: "pa", name: "Punjabi"),
        .init(id: "pl", name: "Polish"),
        .init(id: "ps", name: "Pashto"),
        .init(id: "pt", name: "Portuguese"),
        .init(id: "ro", name: "Romanian"),
        .init(id: "ru", name: "Russian"),
        .init(id: "sa", name: "Sanskrit"),
        .init(id: "sd", name: "Sindhi"),
        .init(id: "si", name: "Sinhala"),
        .init(id: "sk", name: "Slovak"),
        .init(id: "sl", name: "Slovenian"),
        .init(id: "sn", name: "Shona"),
        .init(id: "so", name: "Somali"),
        .init(id: "sq", name: "Albanian"),
        .init(id: "sr", name: "Serbian"),
        .init(id: "su", name: "Sundanese"),
        .init(id: "sv", name: "Swedish"),
        .init(id: "sw", name: "Swahili"),
        .init(id: "ta", name: "Tamil"),
        .init(id: "te", name: "Telugu"),
        .init(id: "tg", name: "Tajik"),
        .init(id: "th", name: "Thai"),
        .init(id: "tk", name: "Turkmen"),
        .init(id: "tl", name: "Tagalog"),
        .init(id: "tr", name: "Turkish"),
        .init(id: "tt", name: "Tatar"),
        .init(id: "uk", name: "Ukrainian"),
        .init(id: "ur", name: "Urdu"),
        .init(id: "uz", name: "Uzbek"),
        .init(id: "vi", name: "Vietnamese"),
        .init(id: "yi", name: "Yiddish"),
        .init(id: "yo", name: "Yoruba"),
        .init(id: "zh", name: "Chinese")
    ]
}

struct CaptionTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String

    var previewVideoURL: URL? {
        switch id {
        case "serif-storyteller":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Serif-storyteller.mp4")
        case "ivory-spotlight":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Ivory-Spotlight.mp4")
        case "authority":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Authority.mp4")
        case "bold-clean":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Bold%20Clean.mp4")
        case "minimalist":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Minimalist.mp4")
        case "justified":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/justified.mp4")
        case "minimalist-white":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Minimalist%20White.mp4")
        case "kinetic":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Kinetic.mp4")
        case "kinetic-yellow":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/Kinetic%20Yellow.mp4")
        case "one-word":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/One%20word.mp4")
        default:
            return URL(string: "https://subclipweb.subclip.app/video-37.mp4")
        }
    }

    var previewThumbnailURL: URL? {
        switch id {
        case "serif-storyteller":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/serif-storyteller.jpg")
        case "ivory-spotlight":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/ivory-spotlight.jpg")
        case "authority":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/authority.jpg")
        case "bold-clean":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/bold-clean.jpg")
        case "minimalist":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/minimalist.jpg")
        case "justified":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/justified.jpg")
        case "minimalist-white":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/minimalist-white.jpg")
        case "kinetic":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/kinetic.jpg")
        case "kinetic-yellow":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/kinetic-yellow.jpg")
        case "one-word":
            return URL(string: "https://subclipweb.subclip.app/dynamic-captions/thumbnails/one-word.jpg")
        default:
            return URL(string: "https://subclipweb.subclip.app/template-preview-thumb.jpg")
        }
    }

    static let all: [CaptionTemplate] = [
        .init(id: "bold-clean", name: "Bold Clean", description: "Large clean words with punchy emphasis."),
        .init(id: "ivory-spotlight", name: "Spotlight", description: "Elegant serif captions with strong focus words."),
        .init(id: "serif-storyteller", name: "Storyteller", description: "Editorial serif captions for narrative videos."),
        .init(id: "authority", name: "Authority", description: "Compact premium captions for expert-style videos."),
        .init(id: "minimalist", name: "Minimalist", description: "Tight, simple captions with restrained motion."),
        .init(id: "justified", name: "Justified", description: "Wider readable lines for dense explanations."),
        .init(id: "minimalist-white", name: "Minimalist White", description: "Clean white captions for simple edits."),
        .init(id: "kinetic", name: "Kinetic", description: "Fast animated captions for energetic clips."),
        .init(id: "kinetic-yellow", name: "Kinetic Yellow", description: "Kinetic captions with yellow emphasis."),
        .init(id: "one-word", name: "One Word", description: "One word at a time for strong hook moments.")
    ]
}

enum OutputAspectRatio: String, CaseIterable, Identifiable {
    case vertical = "9:16"
    case landscape = "16:9"
    case square = "1:1"

    var id: String { rawValue }

    var previewAspect: CGFloat {
        switch self {
        case .vertical:
            return 9.0 / 16.0
        case .landscape:
            return 16.0 / 9.0
        case .square:
            return 1
        }
    }

    var previewMaxWidth: CGFloat? {
        switch self {
        case .vertical:
            return 280
        case .landscape:
            return nil
        case .square:
            return 420
        }
    }
}

enum CaptionPlacement: String, CaseIterable, Identifiable {
    case top
    case middle
    case bottom

    var id: String { rawValue }

    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

struct VideoMetadata: Equatable {
    let durationSeconds: Double
    let width: Int
    let height: Int
    let fileSize: Int64
    let contentType: String

    var durationLabel: String {
        let seconds = max(0, Int(durationSeconds.rounded()))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):\(String(format: "%02d", remainder))"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var dimensionsLabel: String {
        guard width > 0, height > 0 else { return "Unknown size" }
        return "\(width)x\(height)"
    }

    var inferredAspectRatio: OutputAspectRatio? {
        guard width > 0, height > 0 else { return nil }
        let ratio = Double(width) / Double(height)
        if ratio > 1.2 { return .landscape }
        if ratio < 0.8 { return .vertical }
        return .square
    }
}

struct SelectedVideo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileName: String
    let securityScoped: Bool
    let metadata: VideoMetadata
}

struct SelectedSRT: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileName: String
    let fileSize: Int64
    let securityScoped: Bool

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct AppMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct LocalUploadQueueItem: Identifiable, Codable, Equatable {
    let id: UUID
    let projectId: String
    let fileName: String
    let templateId: String
    let aspectRatio: String
    let createdAt: Date
    var status: String
    var outputFileName: String?

    init(
        id: UUID = UUID(),
        projectId: String,
        fileName: String,
        templateId: String,
        aspectRatio: String,
        createdAt: Date = Date(),
        status: String,
        outputFileName: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.fileName = fileName
        self.templateId = templateId
        self.aspectRatio = aspectRatio
        self.createdAt = createdAt
        self.status = status
        self.outputFileName = outputFileName
    }
}

enum LocalUploadQueueStore {
    private static let key = "localUploadQueue"
    private static let limit = 20

    static func load() -> [LocalUploadQueueItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LocalUploadQueueItem].self, from: data)) ?? []
    }

    static func save(_ items: [LocalUploadQueueItem]) {
        let trimmed = Array(items.prefix(limit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension UTType {
    static var srt: UTType {
        UTType(filenameExtension: "srt") ?? .plainText
    }
}

func sanitizedFileName(_ value: String, fallback: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
    let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? fallback : cleaned
}

func mimeType(for url: URL, fallback: String = "video/mp4") -> String {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "mov", "qt":
        return "video/quicktime"
    case "webm":
        return "video/webm"
    case "mkv":
        return "video/x-matroska"
    case "mpg", "mpeg":
        return "video/mpeg"
    case "mp4", "m4v":
        return "video/mp4"
    default:
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? fallback
    }
}
