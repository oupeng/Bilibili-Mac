import SwiftUI

extension View {
    /// 临时反馈的读屏通告：`trigger` 变化且 `message` 不为 nil 时向 VoiceOver 发一次通告。
    ///
    /// 全仓的读屏通告只经这里发出。只用于用户需要知道、但在屏幕上一闪而过或不在读屏焦点处的反馈（快捷键结果、
    /// 失败原因、远端推动的状态变化）；焦点元素自己会读出的内容不再通告。视图首次出现时不发，只有变化才发：
    /// 切回来源页时已有的失败原因不会重读。
    ///
    /// `trigger` 决定“是不是一条新反馈”：同一句话需要连续再报时（同一操作按两次）传每次都不同的标识，否则直接传
    /// `message`。`interruptsPrevious` 为 true 时用高优先级，新通告打断还没读完的旧通告，长按或连按快捷键时
    /// 只听到最新结果，不排队。
    public func accessibilityAnnouncement<Trigger: Equatable>(
        _ message: String?,
        trigger: Trigger,
        interruptsPrevious: Bool = false
    ) -> some View {
        onChange(of: trigger) { _, _ in
            guard let message else { return }
            var announcement = AttributedString(message)
            announcement.accessibilitySpeechAnnouncementPriority =
                interruptsPrevious ? .high : .default
            AccessibilityNotification.Announcement(announcement).post()
        }
    }
}
