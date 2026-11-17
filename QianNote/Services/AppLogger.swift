import Foundation
import os

// MARK: - App 日志采集
//
// 需求背景：用户需要在 iPad 上采集「操作日志 + 异常日志」，并能导出 / 上传到 GitHub，
// 用于排查手写、渲染、崩溃等问题。因为开发机（公司电脑）出不了外网，上传入口放在 App 里。
//
// 设计：
// 1. 用 os.Logger（统一日志系统）+ 一份内存环形缓冲 + 落盘文件，三路都写。
// 2. 日志分类：`info`（操作）、`warning`（非致命异常）、`error`（异常）。
// 3. 落盘文件按天分卷，最多保留 N 个，防止无限增长。
// 4. 崩溃日志：App 启动时把上一次运行结束标志检查一遍，如果发现「异常退出」就记录一条。

final class AppLogger {
    static let shared = AppLogger()

    /// 系统统一日志（Console.app 里可查）
    private let osLog = Logger(subsystem: "com.example.qiannote", category: "app")

    /// 内存环形缓冲（供「关于页」里即时预览最近日志）
    private var buffer: [String] = []
    private let bufferLimit = 200
    private let bufferLock = NSLock()

    /// 落盘目录
    private let logDirectory: URL

    /// 每次启动写的「运行标记」文件：下次启动若发现标记还在（没被正常清理），
    /// 说明上次是异常退出（崩溃 / 被杀），补一条异常日志。
    private let runMarkerURL: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        logDirectory = base.appendingPathComponent("Logs", isDirectory: true)
        runMarkerURL = base.appendingPathComponent("run.marker")

        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        detectAbnormalExit()
        markRunning()
    }

    // MARK: - 对外写入接口

    func info(_ message: String) {
        write(level: "INFO", message: message)
        osLog.info("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        write(level: "WARN", message: message)
        osLog.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
        osLog.error("\(message, privacy: .public)")
    }

    /// 记录一次 NSError / Error
    func error(_ error: Error, context: String = "") {
        let desc = context.isEmpty ? "\(error)" : "\(context)：\(error)"
        self.error(desc)
    }

    // MARK: - 内部写入

    private func write(level: String, message: String) {
        let formatter = Self.timestampFormatter
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)"

        // 内存缓冲
        bufferLock.lock()
        buffer.append(line)
        if buffer.count > bufferLimit {
            buffer.removeFirst(buffer.count - bufferLimit)
        }
        bufferLock.unlock()

        // 落盘（追加写，带换行）
        let url = todayFileURL()
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - 文件管理

    private func todayFileURL() -> URL {
        let name = "qiannote-\(Self.fileDateFormatter.string(from: Date())).log"
        return logDirectory.appendingPathComponent(name)
    }

    /// 所有日志文件（按文件名倒序 = 最新的在前）
    func logFiles() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory,
                                                      includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 把内存缓冲里的最近日志转成一段文本（供预览）
    func recentLines() -> String {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return buffer.joined(separator: "\n")
    }

    /// 把所有日志文件合并成一份文本（导出 / 上传用）
    func combinedLog() -> String {
        var parts: [String] = []
        for url in logFiles() {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                parts.append(content)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// 清理超过 retention 天的旧日志
    func purgeOldLogs(olderThanDays days: Int = 14) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for url in logFiles() {
            let name = url.deletingPathExtension().lastPathComponent
            if let date = Self.fileDateFormatter.date(from: name), date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - 崩溃检测

    private func markRunning() {
        let data = Data()
        try? data.write(to: runMarkerURL)
    }

    /// 正常退出（App 走 didEnterBackground 不删；真正「正常结束」其实很少发生，
    /// 这里主要在下次启动时判断：标记还在 = 上次没走到清理 = 异常退出）。
    private func detectAbnormalExit() {
        guard FileManager.default.fileExists(atPath: runMarkerURL.path) else {
            // 没有标记文件 = 上次是首次启动或正常清理过，不记录
            return
        }
        // 标记还在，说明上次进程没走到 markRunning 之后被清理——多半是崩溃或被系统回收
        write(level: "ERROR", message: "检测到上次会话异常退出（可能崩溃或被系统终止）。")
    }

    /// 供测试 / 调试用：清理运行标记（模拟正常退出）
    func clearRunMarker() {
        try? FileManager.default.removeItem(at: runMarkerURL)
    }

    // MARK: - 静态格式化器

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
