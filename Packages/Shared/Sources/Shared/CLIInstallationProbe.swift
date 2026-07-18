import Foundation

#if os(macOS)

/// Honest production installation probe shared by provider adapters.
/// A CLI that exists but cannot report its version is marked broken rather
/// than receiving a guessed version string.
enum CLIInstallationProbe {
    static func inspect(executablePath: String, versionArguments: [String] = ["--version"]) async -> AgentInstallation {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return AgentInstallation(state: .notInstalled, executablePath: nil)
        }
        do {
            let output = try await Task.detached(priority: .utility) {
                try BoundedProcessRunner.run(
                    executable: executablePath,
                    arguments: versionArguments,
                    timeoutSeconds: 5
                )
            }.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else {
                return AgentInstallation(state: .broken(reason: "version command returned no output"), executablePath: executablePath)
            }
            return AgentInstallation(state: .installed(version: String(output.prefix(120))), executablePath: executablePath)
        } catch {
            return AgentInstallation(state: .broken(reason: error.localizedDescription), executablePath: executablePath)
        }
    }
}

#endif
