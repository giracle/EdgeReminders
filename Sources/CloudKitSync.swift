import CloudKit
import Combine
import Foundation

/// 手动 CloudKit 同步：把本机清单整包推到私有数据库，另一台设备拉回恢复。
/// 冲突策略为「最后写入获胜」，记录里带时间戳用于比较。
@MainActor
final class CloudKitSync: ObservableObject {
    enum Status: Equatable {
        case idle
        case working
        case ready
        case denied
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published var containerID: String {
        didSet { defaults.set(containerID, forKey: Keys.container) }
    }

    private let store: TaskStore
    private let defaults: UserDefaults

    private enum Keys {
        static let container = "cloudkit.containerID"
        static let lastPushEpoch = "cloudkit.lastPushEpoch"
        static let lastPullEpoch = "cloudkit.lastPullEpoch"
    }

    private enum SyncError: LocalizedError {
        case noAccount
        case unknown

        var errorDescription: String? {
            switch self {
            case .noAccount: "iCloud 账号不可用。请在系统设置中登录 iCloud 后再试。"
            case .unknown: "无法确认 iCloud 状态，请稍后重试。"
            }
        }
    }

    static let defaultContainerID = "iCloud.local.fuguang.EdgeReminders"
    private static let recordType = "fuguang.localdata.v1"
    private static let recordName = "main"

    init(store: TaskStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.containerID = defaults.string(forKey: Keys.container) ?? Self.defaultContainerID
    }

    var lastPushDate: Date? {
        let epoch = defaults.double(forKey: Keys.lastPushEpoch)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    var lastPullDate: Date? {
        let epoch = defaults.double(forKey: Keys.lastPullEpoch)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    private func makeContainer() -> CKContainer {
        CKContainer(identifier: containerID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func refreshAuthorization() async {
        do {
            switch try await makeContainer().accountStatus() {
            case .available:
                status = .ready
            case .noAccount, .restricted:
                status = .denied
            case .couldNotDetermine, .temporarilyUnavailable:
                status = .failed("无法确认 iCloud 状态，请稍后重试。")
            @unknown default:
                status = .failed("iCloud 状态未知。")
            }
        } catch {
            status = .failed("无法连接 iCloud：\(error.localizedDescription)")
        }
    }

    private func readyDatabase() async throws -> CKDatabase {
        let container = makeContainer()
        switch try await container.accountStatus() {
        case .available:
            return container.privateCloudDatabase
        case .noAccount, .restricted:
            throw SyncError.noAccount
        default:
            throw SyncError.unknown
        }
    }

    /// 上传本机数据。返回记录时间戳。
    @discardableResult
    func push() async -> Int64? {
        status = .working
        do {
            let database = try await readyDatabase()
            let payload = store.backupData()
            let epoch = Int64(Date.now.timeIntervalSince1970)
            let recordID = CKRecord.ID(recordName: Self.recordName)
            let record: CKRecord
            if let existing = try? await database.record(for: recordID) {
                record = existing
            } else {
                record = CKRecord(recordType: Self.recordType, recordID: recordID)
            }
            record.setValue(payload, forKey: "payload")
            record.setValue(epoch, forKey: "epoch")
            _ = try await database.save(record)
            defaults.set(Double(epoch), forKey: Keys.lastPushEpoch)
            status = .ready
            return epoch
        } catch {
            status = .failed(friendly(error))
            return nil
        }
    }

    /// 从云端恢复。返回是否真的恢复了（云端更新时）。
    @discardableResult
    func pull() async -> Bool {
        status = .working
        do {
            let database = try await readyDatabase()
            let recordID = CKRecord.ID(recordName: Self.recordName)
            let record = try await database.record(for: recordID)
            guard let payload = record.value(forKey: "payload") as? Data else {
                status = .failed("云端还没有数据。请先在任意一台设备上上传。")
                return false
            }
            let epoch = (record.value(forKey: "epoch") as? NSNumber)?.doubleValue ?? 0
            let localEpoch = defaults.double(forKey: Keys.lastPushEpoch)
            guard epoch > localEpoch else {
                status = .ready
                return false
            }
            try store.restore(from: payload)
            defaults.set(epoch, forKey: Keys.lastPullEpoch)
            defaults.set(epoch, forKey: Keys.lastPushEpoch)
            status = .ready
            return true
        } catch {
            status = .failed(friendly(error))
            return false
        }
    }

    private func friendly(_ error: Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated, .accountTemporarilyUnavailable:
                return "iCloud 账号不可用。请登录 iCloud 后再试。"
            case .networkUnavailable, .networkFailure:
                return "网络不可用，请稍后再试。"
            case .requestRateLimited:
                return "iCloud 请求太频繁，请稍后再试。"
            case .unknownItem:
                return "云端还没有数据。请先在任意一台设备上上传。"
            case .zoneNotFound:
                return "云端容器缺少数据区，请先上传一次。"
            case .badContainer, .serviceUnavailable:
                return "iCloud 容器不可用，请确认容器 ID 与开发者后台一致。"
            default:
                return "同步失败：\(ckError.localizedDescription)"
            }
        }
        if let syncError = error as? SyncError {
            return syncError.localizedDescription
        }
        return "同步失败：\(error.localizedDescription)"
    }
}
