import Foundation

public struct NotificationItem: Identifiable, Codable, Sendable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let title: String
    public let text: String
    public let timestamp: Date
    public let iconBase64: String?
    
    public init(
        id: String = UUID().uuidString,
        packageName: String,
        appName: String,
        title: String,
        text: String,
        timestamp: Date = Date(),
        iconBase64: String? = nil
    ) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.text = text
        self.timestamp = timestamp
        self.iconBase64 = iconBase64
    }
}
