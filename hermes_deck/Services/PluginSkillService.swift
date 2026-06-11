import Foundation

enum HermesToolListParser {
    static func parse(_ data: Data) -> [HermesInstalledTool] {
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var tools: [HermesInstalledTool] = []
        var currentSource = ""

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasSuffix(":"), let source = sourceName(from: line) {
                currentSource = source
                continue
            }

            guard !currentSource.isEmpty, let tool = parseToolLine(line, source: currentSource) else {
                continue
            }
            tools.append(tool)
        }

        return tools.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func sourceName(from header: String) -> String? {
        let title = String(header.dropLast()).trimmingCharacters(in: .whitespaces)
        guard let range = title.range(of: " toolsets") else { return nil }
        let source = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return source.isEmpty ? nil : source
    }

    private static func parseToolLine(_ line: String, source: String) -> HermesInstalledTool? {
        guard line.hasPrefix("✓ ") || line.hasPrefix("✗ ") else { return nil }
        let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 3 else { return nil }

        let status = parts[1].capitalized
        let name = parts[2]
        let summary = parts.count >= 4 ? parts[3].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) : ""

        return HermesInstalledTool(
            id: "\(source)-\(name)",
            name: name,
            source: source,
            status: status,
            summary: summary
        )
    }
}

enum HermesSkillListParser {
    static func parse(_ data: Data) -> [HermesInstalledSkill] {
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.components(separatedBy: .newlines).compactMap(parseLine)
    }

    private static func parseLine(_ line: String) -> HermesInstalledSkill? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("│"), trimmed.hasSuffix("│") else { return nil }

        let columns = trimmed
            .dropFirst()
            .dropLast()
            .split(separator: "│", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard columns.count == 5, columns[0] != "Name", !columns[0].isEmpty else {
            return nil
        }

        return HermesInstalledSkill(
            id: columns[0],
            name: columns[0],
            category: columns[1],
            source: columns[2],
            trust: columns[3],
            status: columns[4]
        )
    }
}

struct LocalHermesPluginProvider: HermesPluginProvider {
    var configURL: URL
    var userPluginsURL: URL
    var bundledPluginsURL: URL
    var hermesExecutableURL: URL
    var hermesArgumentsPrefix: [String]
    var rootURL: URL

    nonisolated init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml"),
        userPluginsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/plugins"),
        bundledPluginsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/plugins"),
        hermesExecutableURL: URL = LocalHermesPluginProvider.defaultHermesExecutableURL(),
        hermesArgumentsPrefix: [String] = [],
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    ) {
        self.configURL = configURL
        self.userPluginsURL = userPluginsURL
        self.bundledPluginsURL = bundledPluginsURL
        self.hermesExecutableURL = hermesExecutableURL
        self.hermesArgumentsPrefix = hermesArgumentsPrefix
        self.rootURL = rootURL
    }

    func installedTools(profile: HermesProfile) async throws -> [HermesInstalledTool] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["tools", "list"]
        let environment = Self.environment(for: profile, rootURL: rootURL)

        return try await Task.detached(priority: .utility) {
            let result = try await Self.runHermesList(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment
            )
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes tools list failed"
                throw NSError(domain: "HermesTools", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }
            return HermesToolListParser.parse(result.output)
        }.value
    }

    func setTool(_ name: String, enabled: Bool, profile: HermesProfile) async throws {
        let configURL = Self.configURL(for: profile, rootURL: rootURL)
        try await Task.detached(priority: .utility) {
            try Self.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["tools", "enabled"],
                disabledPath: ["tools", "disabled"],
                in: configURL
            )
        }.value
    }

    static func environment(for profile: HermesProfile, rootURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_HOME"] = home(for: profile, rootURL: rootURL).path(percentEncoded: false)
        return environment
    }

    static func home(for profile: HermesProfile, rootURL: URL) -> URL {
        let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id == "default" || id.isEmpty { return rootURL }
        return rootURL.appendingPathComponent("profiles").appendingPathComponent(id)
    }

    static func configURL(for profile: HermesProfile, rootURL: URL) -> URL {
        home(for: profile, rootURL: rootURL).appendingPathComponent("config.yaml")
    }

    static func defaultHermesExecutableURL() -> URL {
        let localBinURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hermes")
        if FileManager.default.isExecutableFile(atPath: localBinURL.path(percentEncoded: false)) {
            return localBinURL
        }

        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes")
    }

    func installedPlugins() async throws -> [HermesInstalledPlugin] {
        let configURL = configURL
        let userPluginsURL = userPluginsURL
        let bundledPluginsURL = bundledPluginsURL

        return try await Task.detached(priority: .utility) {
            let configuredStatuses = try Self.configuredStatuses(from: configURL)
            return try Self.pluginManifests(userPluginsURL: userPluginsURL, bundledPluginsURL: bundledPluginsURL).values.map { pluginManifest in
                var plugin = pluginManifest.plugin
                plugin.status = configuredStatuses[plugin.name] ?? "Available"
                return plugin
            }.sorted { lhs, rhs in
                let statusOrder = ["Enabled": 0, "Disabled": 1, "Available": 2]
                let lhsStatusOrder = statusOrder[lhs.status] ?? 3
                let rhsStatusOrder = statusOrder[rhs.status] ?? 3
                if lhsStatusOrder != rhsStatusOrder {
                    return lhsStatusOrder < rhsStatusOrder
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }.value
    }

    func installedTools() async throws -> [HermesInstalledTool] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["tools", "list"]

        return try await Task.detached(priority: .utility) {
            let result = try await Self.runHermesList(executableURL: executableURL, arguments: arguments)
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes tools list failed"
                throw NSError(domain: "HermesTools", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }

            return HermesToolListParser.parse(result.output)
        }.value
    }

    func setPlugin(_ name: String, enabled: Bool) async throws {
        let configURL = configURL

        try await Task.detached(priority: .utility) {
            try Self.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["plugins", "enabled"],
                disabledPath: ["plugins", "disabled"],
                in: configURL
            )
        }.value
    }

    func setTool(_ name: String, enabled: Bool) async throws {
        let configURL = configURL

        try await Task.detached(priority: .utility) {
            try Self.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["tools", "enabled"],
                disabledPath: ["tools", "disabled"],
                in: configURL
            )
        }.value
    }

    fileprivate static func setConfiguredName(
        _ name: String,
        enabled: Bool,
        enabledPath: [String],
        disabledPath: [String],
        in configURL: URL
    ) throws {
        let config = HermesConfigurationFile(url: configURL)
        try config.load()

        var enabledNames = try config.stringArray(at: enabledPath)
        var disabledNames = try config.stringArray(at: disabledPath)
        enabledNames.removeAll { $0 == name }
        disabledNames.removeAll { $0 == name }

        if enabled {
            enabledNames.append(name)
        } else {
            disabledNames.append(name)
        }

        try config.setStringArray(enabledNames, at: enabledPath)
        try config.setStringArray(disabledNames, at: disabledPath)
        try config.save()
    }

    fileprivate nonisolated static func runHermesList(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output

        try process.runTranslatingMissingCommand(named: "Hermes")
        let outputDataTask = Task {
            output.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        return (process.terminationStatus, await outputDataTask.value)
    }

    private static func configuredStatuses(from configURL: URL) throws -> [String: String] {
        let config = HermesConfigurationFile(url: configURL)
        try config.load()
        let configuredPlugins = HermesPluginConfigurationParser.parse(config.yaml)
        return Dictionary(uniqueKeysWithValues: configuredPlugins.map { ($0.name, $0.status) })
    }

    private static func pluginManifests(userPluginsURL: URL, bundledPluginsURL: URL) throws -> [String: ParsedPluginManifest] {
        let manifestURLs = manifestURLs(in: [userPluginsURL, bundledPluginsURL])
        var pluginsByName: [String: ParsedPluginManifest] = [:]

        for manifestURL in manifestURLs {
            let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
            let manifest = PluginManifest.parse(manifestText)
            let source = sourceName(for: manifestURL, userPluginsURL: userPluginsURL)
            let plugin = manifest.plugin(source: source, path: manifestURL.deletingLastPathComponent().path(percentEncoded: false))
            if pluginsByName[plugin.name]?.plugin.source != "Local" {
                pluginsByName[plugin.name] = ParsedPluginManifest(plugin: plugin, manifest: manifest)
            }
        }

        return pluginsByName
    }

    private struct ParsedPluginManifest {
        var plugin: HermesInstalledPlugin
        var manifest: PluginManifest
    }

    private static func manifestURLs(in roots: [URL]) -> [URL] {
        roots.flatMap { root in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else {
                return [URL]()
            }

            return enumerator.compactMap { item in
                guard let url = item as? URL, url.lastPathComponent == "plugin.yaml" else {
                    return nil
                }
                return url
            }
        }
    }

    private static func sourceName(for manifestURL: URL, userPluginsURL: URL) -> String {
        manifestURL.standardizedFileURL.path.hasPrefix(userPluginsURL.standardizedFileURL.path) ? "Local" : "Bundled"
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = String(parts[1]).pluginCleanedYAMLValue
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private struct PluginManifest {
        var fields: [String: String]
        var lists: [String: [String]]

        static func parse(_ text: String) -> PluginManifest {
            var fields: [String: String] = [:]
            var lists: [String: [String]] = [:]
            var currentListKey: String?

            for rawLine in text.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

                if trimmed.hasPrefix("- ") {
                    if let currentListKey {
                        lists[currentListKey, default: []].append(String(trimmed.dropFirst(2)).pluginCleanedYAMLValue)
                    }
                    continue
                }

                guard let (key, value) = keyValue(trimmed) else { continue }
                if value.isEmpty {
                    currentListKey = key
                    lists[key] = []
                } else {
                    currentListKey = nil
                    fields[key] = value
                }
            }

            return PluginManifest(fields: fields, lists: lists)
        }

        func plugin(source: String, path: String) -> HermesInstalledPlugin {
            let name = fields["name"] ?? URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            let capabilities = [
                lists["provides_tools"],
                lists["provides_web_providers"],
                lists["provides_browser_providers"],
                lists["provides_image_gen_providers"],
                lists["provides_video_gen_providers"],
                lists["provides_memory_providers"],
                lists["hooks"],
            ].compactMap { $0 }.flatMap { $0 }

            return HermesInstalledPlugin(
                id: "\(source)-\(name)",
                name: name,
                displayName: name,
                version: fields["version"]?.pluginTextValue ?? "Unknown",
                source: source,
                category: fields["kind"]?.pluginTextValue ?? "",
                developerName: fields["author"]?.pluginTextValue ?? "",
                summary: fields["description"]?.pluginFirstParagraph ?? "",
                capabilities: capabilities,
                path: path
            )
        }
    }
}

struct LocalHermesSkillProvider: HermesSkillProvider {
    var configURL: URL
    var hermesExecutableURL: URL
    var hermesArgumentsPrefix: [String]
    var rootURL: URL

    nonisolated init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml"),
        hermesExecutableURL: URL = LocalHermesPluginProvider.defaultHermesExecutableURL(),
        hermesArgumentsPrefix: [String] = [],
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    ) {
        self.configURL = configURL
        self.hermesExecutableURL = hermesExecutableURL
        self.hermesArgumentsPrefix = hermesArgumentsPrefix
        self.rootURL = rootURL
    }

    func installedSkills(profile: HermesProfile) async throws -> [HermesInstalledSkill] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["skills", "list"]
        let environment = LocalHermesPluginProvider.environment(for: profile, rootURL: rootURL)

        return try await Task.detached(priority: .utility) {
            let result = try await LocalHermesPluginProvider.runHermesList(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment
            )
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes skills list failed"
                throw NSError(domain: "HermesSkills", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }

            return HermesSkillListParser.parse(result.output)
        }.value
    }

    func setSkill(_ name: String, enabled: Bool, profile: HermesProfile) async throws {
        let configURL = LocalHermesPluginProvider.configURL(for: profile, rootURL: rootURL)
        try await Task.detached(priority: .utility) {
            try LocalHermesPluginProvider.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["skills", "enabled"],
                disabledPath: ["skills", "disabled"],
                in: configURL
            )
        }.value
    }

    func installedSkills() async throws -> [HermesInstalledSkill] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["skills", "list"]

        return try await Task.detached(priority: .utility) {
            let result = try await LocalHermesPluginProvider.runHermesList(
                executableURL: executableURL,
                arguments: arguments
            )
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes skills list failed"
                throw NSError(domain: "HermesSkills", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }

            return HermesSkillListParser.parse(result.output)
        }.value
    }

    func setSkill(_ name: String, enabled: Bool) async throws {
        let configURL = configURL

        try await Task.detached(priority: .utility) {
            try LocalHermesPluginProvider.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["skills", "enabled"],
                disabledPath: ["skills", "disabled"],
                in: configURL
            )
        }.value
    }
}

enum HermesPluginConfigurationParser {
    static func parse(_ config: String) -> [ConfiguredPlugin] {
        let configuredNames = pluginNamesByStatus(in: config)
        let enabled = configuredNames.enabled
            .map { ConfiguredPlugin(name: $0, status: "Enabled") }
        let disabled = configuredNames.disabled
            .map { ConfiguredPlugin(name: $0, status: "Disabled") }

        var seen: Set<String> = []
        return (enabled + disabled).filter { plugin in
            seen.insert(plugin.name).inserted
        }
    }

    static func pluginNamesByStatus(in config: String) -> (enabled: [String], disabled: [String]) {
        (
            pluginNames(in: block(named: "enabled", under: "plugins", in: config)),
            pluginNames(in: block(named: "disabled", under: "plugins", in: config))
        )
    }

    private static func pluginNames(in block: String?) -> [String] {
        guard let block else { return [] }
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[]" { return [] }
        return block.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2)).pluginCleanedYAMLValue.pluginTextValue
        }
    }

    private static func block(named name: String, under parent: String, in yaml: String) -> String? {
        let lines = yaml.components(separatedBy: .newlines)
        guard let parentIndex = lines.firstIndex(where: { $0 == "\(parent):" }) else { return nil }
        guard let start = lines.dropFirst(parentIndex + 1).firstIndex(where: { line in
            line == "  \(name):" || line.hasPrefix("  \(name): ")
        }) else {
            return nil
        }

        let parts = lines[start].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let inlineValue = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !inlineValue.isEmpty {
                return inlineValue
            }
        }

        var blockLines: [String] = []
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("  "), trimmed.hasPrefix("- ") {
                blockLines.append(line)
                continue
            }
            if !trimmed.isEmpty {
                break
            }
            blockLines.append(line)
        }
        return blockLines.joined(separator: "\n")
    }

    struct ConfiguredPlugin: Hashable, Sendable {
        var name: String
        var status: String
    }
}
