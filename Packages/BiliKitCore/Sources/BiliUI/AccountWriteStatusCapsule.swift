import BiliApplication
import SwiftUI

/// 账户写入结果的胶囊：盖在窗口主区底部，成功或失败都用一句话说明，并在每次新结果出现时发一次读屏通告。
///
/// 外形与刷新、分页胶囊同源（`StatusCapsuleGeometry`），出现与消失按 `LoadingStateTransition` 淡入淡出。只负责排版、
/// 措辞与通告；显示哪一条、显示多久由 App 的写入协调者决定（`sequence` 每条新结果递增，相同结果连续出现也会再通告）。
public struct AccountWriteStatusCapsule: View {
    private typealias Geometry = StatusCapsuleGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let report: AccountWriteReport?
    private let sequence: UInt64

    public init(report: AccountWriteReport?, sequence: UInt64) {
        self.report = report
        self.sequence = sequence
    }

    public var body: some View {
        ZStack {
            if let report {
                Label {
                    Text(AccountWriteStatusText.message(for: report))
                        .lineLimit(Geometry.messageLineLimit)
                } icon: {
                    Image(
                        systemName: report.failure == nil
                            ? "checkmark.circle" : "exclamationmark.circle"
                    )
                }
                .font(.callout)
                .padding(Geometry.contentPadding)
                .background(.regularMaterial, in: Capsule())
                // 通告已经读出这句话，胶囊本身不再进入读屏焦点顺序。
                .accessibilityHidden(true)
                // 胶囊盖在网格与相关推荐上，不拦截停留期间的点按。
                .allowsHitTesting(false)
                .id(sequence)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Geometry.horizontalInset)
        .padding(.bottom, Geometry.bottomInset)
        .animation(LoadingStateTransition.animation(reduceMotion: reduceMotion), value: sequence)
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: report == nil
        )
        .accessibilityAnnouncement(
            report.map(AccountWriteStatusText.message(for:)),
            trigger: sequence
        )
    }
}

/// 写入结果的文案，胶囊与读屏通告共用。
package enum AccountWriteStatusText {
    package static func message(for report: AccountWriteReport) -> String {
        guard let failure = report.failure else {
            return switch report.change {
            case .watchLaterAdded: BiliUIStrings.localized("已添加到稍后再看")
            case .watchLaterRemoved: BiliUIStrings.localized("已从稍后再看移除")
            }
        }
        let reason = reason(for: failure)
        return switch report.change {
        case .watchLaterAdded: BiliUIStrings.localized("无法添加到稍后再看：\(reason)")
        case .watchLaterRemoved: BiliUIStrings.localized("无法从稍后再看移除：\(reason)")
        }
    }

    private static func reason(for failure: AccountWriteError) -> String {
        switch failure {
        case .authenticationRequired, .authenticationInvalid:
            BiliUIStrings.localized("登录状态可能已失效。")
        case .authenticationUnavailable:
            BiliUIStrings.localized("无法读取登录状态，请稍后再试。")
        case .restricted:
            BiliUIStrings.localized("请求受到限制，请稍后再试。")
        case .listFull:
            BiliUIStrings.localized("稍后再看已满。")
        case .unsupportedContent:
            BiliUIStrings.localized("这个视频不能加入稍后再看。")
        case .contentUnavailable:
            BiliUIStrings.localized("视频不存在或已删除。")
        case .rejected(let code):
            BiliUIStrings.localized("服务拒绝了这次操作（错误码 \(code)）。")
        case .unavailable:
            BiliUIStrings.localized("网络不可用或服务暂时无法完成，请稍后再试。")
        case .invalidRequest:
            BiliUIStrings.localized("当前无法完成这次请求。")
        }
    }
}
