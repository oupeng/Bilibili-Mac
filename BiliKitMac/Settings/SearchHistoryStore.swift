import BiliApplication
import Foundation
import Observation

/// 本机搜索历史，进程内唯一，所有窗口共享同一份。
///
/// 只记录用户提交的搜索词：最近的在前，按规范化后的词去重，最多 `maximumEntryCount` 条，没有时间期限。
/// 历史属于本机而不属于账号：未登录时也记录，登出不清理；用户可在搜索页逐条删除或全部清除。
@MainActor
@Observable
final class SearchHistoryStore {
    static let maximumEntryCount = 20

    private enum Key {
        static let schema = "searchHistory.schema"
        static let entries = "searchHistory.entries"
    }
    private static let schemaVersion = 1

    private(set) var entries: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = Self.load(from: defaults) {
            entries = stored
        } else {
            entries = []
            Self.removeStoredHistory(from: defaults)
        }
    }

    func record(_ query: String) {
        guard let query = Self.normalized(query) else { return }
        save(Array(([query] + entries.filter { $0 != query }).prefix(Self.maximumEntryCount)))
    }

    func remove(_ query: String) {
        save(entries.filter { $0 != query })
    }

    /// 清除时连同 schema 键一起移除，不在本机留下空记录。
    func clear() {
        entries = []
        Self.removeStoredHistory(from: defaults)
    }

    private func save(_ updated: [String]) {
        guard updated != entries else { return }
        entries = updated
        defaults.set(Self.schemaVersion, forKey: Key.schema)
        defaults.set(updated, forKey: Key.entries)
    }

    /// 与搜索提交同一套规范化：去掉首尾空白，空词或超过搜索长度上限的词不记录。
    private static func normalized(_ query: String) -> String? {
        let criteria = VideoSearchCriteria(query: query)
        return criteria.isValid ? criteria.query : nil
    }

    /// schema 不符或类型错写时返回 nil，由调用方删除这两个键；非法条目与重复条目逐条丢弃。
    private static func load(from defaults: UserDefaults) -> [String]? {
        guard defaults.strictInteger(forKey: Key.schema) == schemaVersion,
            let stored = defaults.array(forKey: Key.entries)
        else { return nil }
        var queries: [String] = []
        for case let value as String in stored {
            guard let query = normalized(value), !queries.contains(query) else { continue }
            queries.append(query)
            if queries.count == maximumEntryCount { break }
        }
        return queries
    }

    private static func removeStoredHistory(from defaults: UserDefaults) {
        defaults.removeObject(forKey: Key.entries)
        defaults.removeObject(forKey: Key.schema)
    }
}
