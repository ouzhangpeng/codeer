import Foundation

/// 「鹿」字 PNG（256×256 RGBA 透明底，base64 内嵌）——alpha 即镂空蒙版
enum DeerPNGAsset {
    static let pngBase64 =
        "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"
}
