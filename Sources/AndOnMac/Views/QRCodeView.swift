import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

public struct QRCodeView: View {
    public let payload: String
    public let size: CGFloat
    
    private let context = CIContext()
    
    public init(payload: String, size: CGFloat = 200) {
        self.payload = payload
        self.size = size
    }
    
    public var body: some View {
        if let nsImage = generateQRCode(from: payload) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(12)
                .background(Color.white)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .frame(width: size, height: size)
                .overlay(Text("Не удалось создать QR-код").font(.caption))
        }
    }
    
    private func generateQRCode(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        guard let data = string.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
