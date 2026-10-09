import Accessibility
import BlauCore
import BlauTopics
import SwiftUI

/// What Blau tells VoiceOver about changes on screen the user didn't make
/// (#81, docs/accessibility.md): a new topic, a refined title, a new
/// problem in the issue banner. The rules for topics are BlauKit's
/// `TopicAnnouncer`; this is the wording and the posting.
enum BlauAnnouncement {
    /// The spoken text for a topic change.
    static func text(for announcement: TopicAnnouncer.Announcement) -> String {
        switch announcement {
        case .newTopic(let title?): String(localized: "New topic: \(title)")
        case .newTopic(nil): String(localized: "New topic")
        case .titleRefined(let title): String(localized: "Topic named \(title)")
        }
    }

    /// The spoken text for an issue that just appeared in the banner: its
    /// title and what it means.
    static func text(for issue: UserFacingIssue) -> String {
        "\(issue.title). \(issue.message)"
    }

    /// How urgently VoiceOver should speak a message.
    enum Urgency {
        /// Waits for VoiceOver to finish what it is saying (topics: the user
        /// may be listening to Grok or reading).
        case polite
        /// Interrupts (a problem that stops the conversation).
        case urgent
    }

    /// The announcement as VoiceOver gets it, with its priority.
    static func attributed(_ text: String, urgency: Urgency) -> AttributedString {
        var string = AttributedString(text)
        string.accessibilitySpeechAnnouncementPriority = urgency == .urgent ? .high : .low
        return string
    }

    /// Speaks `text` if VoiceOver (or another assistive technology that
    /// reads announcements) is listening; otherwise it is ignored.
    @MainActor
    static func post(_ text: String, urgency: Urgency) {
        AccessibilityNotification.Announcement(attributed(text, urgency: urgency)).post()
    }
}

extension View {
    /// Announces the timeline's current topic changes to VoiceOver
    /// (`TopicAnnouncer` decides which ones), except the titles the user
    /// typed (`renamedByUser`).
    func announcesTopicChanges(current: TimelineTopic?, renamedByUser: Set<UUID> = []) -> some View {
        modifier(TopicChangeAnnouncements(current: current, renamedByUser: renamedByUser))
    }
}

private struct TopicChangeAnnouncements: ViewModifier {
    let current: TimelineTopic?
    let renamedByUser: Set<UUID>
    @State private var announcer = TopicAnnouncer()

    func body(content: Content) -> some View {
        content.onChange(of: current, initial: true) { _, topic in
            if let announcement = announcer.update(topic, renamedByUser: renamedByUser) {
                BlauAnnouncement.post(BlauAnnouncement.text(for: announcement), urgency: .polite)
            }
        }
    }
}
