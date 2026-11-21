//
//  NativeSearch.swift
//  Runner
//
//  Created by Aaron Madlon-Kay on 2021/06/03.
//

import Foundation
import Flutter
import os

fileprivate let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "NativeSearch"
)

private var jobs = ConcurrentSet<String>()

private var jobTokenForId = "forId:"
private var jobTokenForNamePrefix = "forNamePrefix:"
private var jobTokenForExactName = "forExactName:"
private var jobTokenForRoamNodes = "forRoamNodes:"

func handleNativeSearchMethod(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "findFileForId":
        DispatchQueue.global(qos: .userInitiated).async {
            findFileForId(call, result)
        }
    case "findFileWithNamePrefix":
        DispatchQueue.global(qos: .userInitiated).async {
            findFileWithNamePrefix(call, result)
        }
    case "findFileWithExactName":
        DispatchQueue.global(qos: .userInitiated).async {
            findFileWithExactName(call, result)
        }
    case "cancelFindFileForId":
        cancelFindFile(call, result, token: jobTokenForId)
    case "cancelFindFileWithNamePrefix":
        cancelFindFile(call, result, token: jobTokenForNamePrefix)
    case "cancelFindFileWithExactName":
        cancelFindFile(call, result, token: jobTokenForExactName)
    case "listFiles":
        DispatchQueue.global(qos: .userInitiated).async {
            listFiles(call, result)
        }
    case "resolveInRoot":
        DispatchQueue.global(qos: .userInitiated).async {
            resolveInRoot(call, result)
        }
    case "readOrgFiles":
        DispatchQueue.global(qos: .userInitiated).async {
            readOrgFiles(call, result)
        }
    case "cancelReadOrgFiles":
        cancelFindFile(call, result, token: jobTokenForRoamNodes)
    default:
        result(FlutterError(code: "UnsupportedMethod", message: "\(call.method) is not supported", details: nil))
    }
}

private func cancelFindFile(_ call: FlutterMethodCall, _ result: @escaping FlutterResult, token: String) {
    guard let args = call.arguments as? [String:Any?] else {
        result(FlutterError(code: "MissingArgs", message: "Required arguments missing", details: "\(call.method) requires 'requestId'"))
        return
    }
    guard let requestId = args["requestId"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'requestId'"))
        return
    }
    let removed = jobs.remove("\(token)\(requestId)")
    logger.info("Cancelling job \(token)\(requestId); cancelled: \(removed != nil)")
    result(removed != nil)
}

private func findFileForId(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String:Any?] else {
        result(FlutterError(code: "MissingArgs", message: "Required arguments missing", details: "\(call.method) requires 'id', 'dirIdentifier'"))
        return
    }
    guard var requestId = args["requestId"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'requestId'"))
        return
    }
    requestId = "\(jobTokenForId)\(requestId)"
    jobs.insert(requestId)
    defer {
        jobs.remove(requestId)
    }
    guard let orgId = args["orgId"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'orgId'"))
        return
    }
    guard let dirIdentifier = args["dirIdentifier"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'dirIdentifier'"))
        return
    }

    guard let url = restoreUrl(from: dirIdentifier) else {
        result(FlutterError(code: "InvalidDataError", message: "Unable to restore URL from identifier.", details: nil))
        return
    }

    let found = findFile(at: url, requestId: requestId) { file, name in
        guard name.hasSuffix(".org") || name.hasSuffix(".org.icloud") else {
            return false
        }
        logger.debug("Searching \(file) for ID \(orgId)")
        return withSecurityAccess(to: file) { fileUrl in
            var matched = false
            var fileError: NSError? = nil
            NSFileCoordinator().coordinate(readingItemAt: file, error: &fileError) { fileUrl in
                if fileContainsId(fileUrl: fileUrl, id: orgId) {
                    matched = true
                }
            }
            if let fileError = fileError {
                logger.error("Error accessing file: \(fileError)")
            }
            return matched
        }
    }

    guard let found = found else {
        DispatchQueue.main.async { result(nil) }
        return
    }

    let bookmark = withSecurityAccess(to: found) { url in
        return try? url.bookmarkData()
    }
    guard let bookmark = bookmark else {
        logger.info("Failed to get bookmark for file: \(found)")
        DispatchQueue.main.async { result(nil) }
        return
    }
    DispatchQueue.main.async {
        // Result compatible with file_picker_writable
        result([
            "path": found.path,
            "identifier": bookmark.base64EncodedString(),
            "persistable": "true",
            "uri": found.absoluteString,
            "fileName": found.lastPathComponent,
        ])
    }
}

private func findFileWithNamePrefix(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String:Any?] else {
        result(FlutterError(code: "MissingArgs", message: "Required arguments missing", details: "\(call.method) requires 'id', 'dirIdentifier'"))
        return
    }
    guard var requestId = args["requestId"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'requestId'"))
        return
    }
    requestId = "\(jobTokenForNamePrefix)\(requestId)"
    jobs.insert(requestId)
    defer {
        jobs.remove(requestId)
    }
    guard let namePrefix = args["namePrefix"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'namePrefix'"))
        return
    }
    guard let dirIdentifier = args["dirIdentifier"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'dirIdentifier'"))
        return
    }

    guard let url = restoreUrl(from: dirIdentifier) else {
        result(FlutterError(code: "InvalidDataError", message: "Unable to restore URL from identifier.", details: nil))
        return
    }

    let found = findFile(at: url, requestId: requestId) { file, name  in
        guard name.hasSuffix(".org") || name.hasSuffix(".org.icloud") else {
            return false
        }
        logger.debug("Searching \(file) for file name prefix \(namePrefix)")
        return name.hasPrefix(namePrefix)
    }

    guard let found = found else {
        DispatchQueue.main.async { result(nil) }
        return
    }

    let coordinated = withSecurityAccess(to: found) { url in
        var coordinated: URL? = nil
        var fileError: NSError? = nil
        NSFileCoordinator().coordinate(readingItemAt: url, error: &fileError) { fileUrl in
            coordinated = fileUrl
        }
        if let fileError = fileError {
            logger.error("Error accessing file: \(fileError)")
        }
        return coordinated
    }

    guard let coordinated = coordinated else {
        DispatchQueue.main.async { result(nil) }
        return
    }

    let bookmark = withSecurityAccess(to: coordinated) { url in
        return try? url.bookmarkData()
    }
    guard let bookmark = bookmark else {
        logger.info("Failed to get bookmark for file: \(coordinated)")
        DispatchQueue.main.async { result(nil) }
        return
    }
    DispatchQueue.main.async {
        // Result compatible with file_picker_writable
        result([
            "path": coordinated.path,
            "identifier": bookmark.base64EncodedString(),
            "persistable": "true",
            "uri": coordinated.absoluteString,
            "fileName": coordinated.lastPathComponent,
        ])
    }
}

private func findFileWithExactName(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String:Any?] else {
        result(FlutterError(code: "MissingArgs", message: "Required arguments missing", details: "\(call.method) requires 'id', 'dirIdentifier'"))
        return
    }
    guard var requestId = args["requestId"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'requestId'"))
        return
    }
    requestId = "\(jobTokenForExactName)\(requestId)"
    jobs.insert(requestId)
    defer {
        jobs.remove(requestId)
    }
    guard let exactName = args["exactName"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'exactName'"))
        return
    }
    guard let dirIdentifier = args["dirIdentifier"] as? String else {
        result(FlutterError(code: "MissingArg", message: "Required argument missing", details: "\(call.method) requires 'dirIdentifier'"))
        return
    }

    guard let url = restoreUrl(from: dirIdentifier) else {
        result(FlutterError(code: "InvalidDataError", message: "Unable to restore URL from identifier.", details: nil))
        return
    }

    let found = findFile(at: url, requestId: requestId) { file, name  in
        logger.debug("Searching \(file) for file named \(exactName)")
        return name == exactName
    }

    guard let found = found else {
        DispatchQueue.main.async { result(nil) }
        return
    }

    let coordinated = withSecurityAccess(to: found) { url in
        var coordinated: URL? = nil
        var fileError: NSError? = nil
        NSFileCoordinator().coordinate(readingItemAt: url, error: &fileError) { fileUrl in
            coordinated = fileUrl
        }
        if let fileError = fileError {
            logger.error("Error accessing file: \(fileError)")
        }
        return coordinated
    }

    guard let coordinated = coordinated else {
        DispatchQueue.main.async { result(nil) }
        return
    }

    let bookmark = withSecurityAccess(to: coordinated) { url in
        return try? url.bookmarkData()
    }
    guard let bookmark = bookmark else {
        logger.info("Failed to get bookmark for file: \(coordinated)")
        DispatchQueue.main.async { result(nil) }
        return
    }
    DispatchQueue.main.async {
        // Result compatible with file_picker_writable
        result([
            "path": coordinated.path,
            "identifier": bookmark.base64EncodedString(),
            "persistable": "true",
            "uri": coordinated.absoluteString,
            "fileName": coordinated.lastPathComponent,
        ])
    }
}

private func findFile(at url: URL, requestId: String, predicate: (_ fileUrl: URL, _ name: String) -> Bool) -> URL?  {
    // https://developer.apple.com/documentation/uikit/view_controllers/providing_access_to_directories

    guard url.startAccessingSecurityScopedResource() else {
        logger.error("Failed to access security scoped resource: \(url)")
        return nil
    }

    defer { url.stopAccessingSecurityScopedResource() }

    var error: NSError? = nil
    var result: URL?
    NSFileCoordinator().coordinate(readingItemAt: url, error: &error) { url in
        let keys = Set<URLResourceKey>([.nameKey, .isDirectoryKey])

        guard let fileList =
                FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            logger.error("Failed to obtain enumerator")
            return
        }

        for case let file as URL in fileList {
            guard jobs.contains(requestId) else {
                logger.info("Quitting job \(requestId) due to cancellation")
                break
            }

            logger.debug("Looking at file \(file)")
            guard let values = try? file.resourceValues(forKeys: keys),
                  let isDirectory = values.isDirectory,
                  let name = values.name else {
                logger.error("Failed to access resource values: \(file)")
                continue
            }
            guard !isDirectory else {
                continue
            }
            if predicate(file, name) {
                result = file
                break
            }
        }
    }
    if let error = error {
        logger.error("Error accessing dir: \(error)")
    }
    return result
}

/// Enumerate all .org files under a directory and return each file's content
/// along with a persistent identifier. Node indexing and full-text search
/// happen in Dart.
private func readOrgFiles(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String:Any?],
          var requestId = args["requestId"] as? String,
          let dirIdentifier = args["dirIdentifier"] as? String else {
        result(FlutterError(code: "MissingArgs", message: "Required arguments missing", details: "\(call.method) requires 'requestId', 'dirIdentifier'"))
        return
    }
    requestId = "\(jobTokenForRoamNodes)\(requestId)"
    jobs.insert(requestId)
    defer {
        jobs.remove(requestId)
    }

    guard let url = restoreUrl(from: dirIdentifier) else {
        DispatchQueue.main.async {
            result(FlutterError(code: "InvalidDataError", message: "Unable to restore URL from identifier.", details: nil))
        }
        return
    }

    guard url.startAccessingSecurityScopedResource() else {
        logger.error("Failed to access security scoped resource: \(url)")
        DispatchQueue.main.async { result(nil) }
        return
    }
    defer { url.stopAccessingSecurityScopedResource() }

    var files: [[String:Any]] = []
    var cancelled = false
    var dirError: NSError? = nil
    NSFileCoordinator().coordinate(readingItemAt: url, error: &dirError) { dirUrl in
        let keys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .contentModificationDateKey]
        guard let fileList = FileManager.default.enumerator(
            at: dirUrl,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            logger.error("Failed to obtain enumerator")
            return
        }
        let rootPath = dirUrl.standardizedFileURL.path
        for case let file as URL in fileList {
            guard jobs.contains(requestId) else {
                logger.info("Quitting job \(requestId) due to cancellation")
                cancelled = true
                break
            }
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let isDirectory = values.isDirectory,
                  let name = values.name,
                  !isDirectory,
                  name.hasSuffix(".org") else {
                continue
            }
            autoreleasepool {
                var content: String? = nil
                var fileError: NSError? = nil
                NSFileCoordinator().coordinate(readingItemAt: file, error: &fileError) { fileUrl in
                    content = try? String(contentsOf: fileUrl, encoding: .utf8)
                }
                if let fileError = fileError {
                    logger.error("Error accessing file: \(fileError)")
                    return
                }
                guard let content = content else {
                    logger.info("Failed to read file as UTF-8: \(file)")
                    return
                }
                guard let bookmark = try? file.bookmarkData() else {
                    logger.info("Failed to get bookmark for file: \(file)")
                    return
                }
                var relativePath = file.standardizedFileURL.path
                if relativePath.hasPrefix(rootPath) {
                    relativePath = String(relativePath.dropFirst(rootPath.count))
                    if relativePath.hasPrefix("/") { relativePath.removeFirst() }
                }
                files.append([
                    "identifier": bookmark.base64EncodedString(),
                    "uri": file.absoluteString,
                    "fileName": name,
                    "relativePath": relativePath,
                    "modified": (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000,
                    "content": content,
                ])
            }
        }
    }
    if let dirError = dirError {
        logger.error("Error accessing dir: \(dirError)")
    }
    DispatchQueue.main.async { result(cancelled ? nil : files) }
}

/// List every (non-hidden) file under a granted folder: path relative to the
/// folder, name and modification date. No bookmarks: files are resolved when
/// opened (resolveInRoot with fromRoot).
private func listFiles(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    guard let args = call.arguments as? [String: Any?],
          let dirIdentifier = args["dirIdentifier"] as? String,
          let rootUrl = restoreUrl(from: dirIdentifier) else {
        reply(FlutterError(code: "MissingArgs", message: "listFiles requires a valid 'dirIdentifier'", details: nil))
        return
    }
    let limit = args["limit"] as? Int ?? 50_000
    let accessing = rootUrl.startAccessingSecurityScopedResource()
    defer { if accessing { rootUrl.stopAccessingSecurityScopedResource() } }

    var files: [[String: Any]] = []
    var coordError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: rootUrl, error: &coordError) { dirUrl in
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: dirUrl,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        let rootPath = dirUrl.standardizedFileURL.path
        for case let file as URL in enumerator {
            if files.count >= limit { break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == false,
                  let name = values.name else { continue }
            var relative = file.standardizedFileURL.path
            if relative.hasPrefix(rootPath) {
                relative = String(relative.dropFirst(rootPath.count))
                if relative.hasPrefix("/") { relative.removeFirst() }
            }
            files.append([
                "relativePath": relative,
                "fileName": name.hasSuffix(".icloud") && name.hasPrefix(".") ? String(name.dropFirst().dropLast(7)) : name,
                "modified": (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000,
            ])
        }
    }
    if let coordError = coordError {
        logger.error("listFiles: \(coordError)")
    }
    reply(["rootName": rootUrl.lastPathComponent, "files": files])
}

/// Resolve a path from a document against the root folder the user granted,
/// with access to the root held open. Handles:
/// - relative paths that leave the document's folder ("../images/x.png"),
///   which the document folder's own access doesn't cover
/// - absolute paths from another machine ("/home/me/notes/images/x.png"):
///   the part after the root folder's name is used
private func resolveInRoot(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let reply: (Any?) -> Void = { value in DispatchQueue.main.async { result(value) } }
    guard let args = call.arguments as? [String: Any?],
          let rootIdentifier = args["rootIdentifier"] as? String,
          let fileUri = args["fileUri"] as? String,
          let path = args["path"] as? String else {
        reply(FlutterError(code: "MissingArgs", message: "resolveInRoot requires 'rootIdentifier', 'fileUri', 'path'", details: nil))
        return
    }
    guard let rootUrl = restoreUrl(from: rootIdentifier) else {
        reply(FlutterError(code: "InvalidDataError", message: "Unable to restore root URL", details: nil))
        return
    }
    let accessing = rootUrl.startAccessingSecurityScopedResource()
    defer { if accessing { rootUrl.stopAccessingSecurityScopedResource() } }

    let root = rootUrl.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    var target: URL
    if path.hasPrefix("/") || path.hasPrefix("~") {
        // Find the root folder's name in the foreign absolute path
        let marker = "/\(root.lastPathComponent)/"
        guard let range = path.range(of: marker, options: .backwards) else {
            reply(nil)
            return
        }
        target = root.appendingPathComponent(String(path[range.upperBound...]))
    } else if (args["fromRoot"] as? Bool) == true {
        target = root.appendingPathComponent(path)
    } else {
        guard let fileUrl = URL(string: fileUri) else {
            reply(nil)
            return
        }
        target = fileUrl.deletingLastPathComponent().appendingPathComponent(path)
    }
    target = target.standardizedFileURL.resolvingSymlinksInPath()
    // Stay inside the granted folder
    guard target.path.hasPrefix(rootPath) else {
        reply(nil)
        return
    }
    var coordError: NSError?
    var identifier: String?
    NSFileCoordinator().coordinate(readingItemAt: target, error: &coordError) { _ in
        identifier = try? target.bookmarkData().base64EncodedString()
    }
    guard let identifier = identifier else {
        logger.info("resolveInRoot: no file at \(target.path): \(String(describing: coordError))")
        reply(nil)
        return
    }
    reply([
        "identifier": identifier,
        "persistable": "true",
        "uri": target.absoluteString,
        "fileName": target.lastPathComponent,
    ])
}

private let idPattern = try! NSRegularExpression(pattern: #"^\s*:ID:\s*(?<value>\S+)\s*$"#, options: [.caseInsensitive])

private func fileContainsId(fileUrl: URL, id: String) -> Bool {
    guard let reader = LineReader(url: fileUrl) else {
        logger.error("Failed to instantiate line reader")
        return false
    }
    for line in reader {
        let found = autoreleasepool { () -> Bool in
            guard line.contains(id) else {
                return false
            }
            return findIdInString(line) == id
        }
        if found {
            return true
        }
    }
    return false
}

private func findIdInString(_ str: String) -> String? {
    let range = NSRange(str.startIndex..<str.endIndex, in: str)
    guard let result = idPattern.firstMatch(in: str, range: range) else {
        return nil
    }
    let matchRange = result.range(at: 1)
    guard let valueRange = Range(matchRange, in: str) else {
        return nil
    }
    return String(str[valueRange])
}

private func restoreUrl(from identifier: String) -> URL? {
    guard let bookmark = Data(base64Encoded: identifier) else {
        return nil
    }
    var isStale: Bool = false
    guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else {
        return nil
    }
    logger.debug("url: \(url) / isStale: \(isStale)")
    return url
}

class ConcurrentSet<T: Hashable> {
    private var data: Set<T> = []
    let lock = NSLock()

    func insert(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        data.insert(item)
    }

    func contains(_ item: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.contains(item)
    }

    @discardableResult
    func remove(_ item: T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return data.remove(item)
    }
}

private func withSecurityAccess<T>(to url: URL, _ body: (URL) -> T) -> T {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
        if accessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
    return body(url)
}
