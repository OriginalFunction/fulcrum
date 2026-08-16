import Foundation

/// Runs `tilt` CLI actions that mutate a live instance or the resources a
/// Tiltfile defines.
///
/// Every method here shells out through the injected `CommandRunning` rather
/// than touching `Process` directly, which is what makes it safe to assert on
/// exact argv in tests: a wrong `--port` here triggers a build in the wrong
/// developer's project, or disables the wrong resource.
///
/// CLI surface verified against `tilt <cmd> --help` on v0.36.3:
///
///     tilt trigger <resource>  --port N
///     tilt enable  [names…] | --all | -l <label> | --only    --port N
///     tilt disable [names…] | --all | -l <label>              --port N
///     tilt down    -f <Tiltfile path>   [--delete-namespaces] [--delete-volumes]
public actor TiltActions {
    private let runner: any CommandRunning
    private let binary: URL

    public init(runner: any CommandRunning, binary: URL) {
        self.runner = runner
        self.binary = binary
    }

    /// Manually re-runs a single resource's update, bypassing its trigger mode.
    public func trigger(_ name: String, on instance: TiltInstance) async throws {
        _ = try await runner.run(binary, ["trigger", "--port", "\(instance.webPort)", name])
    }

    /// Enables or disables a single named resource.
    public func setEnabled(_ enabled: Bool, resource: String, on instance: TiltInstance) async throws {
        _ = try await runner.run(binary, [subcommand(for: enabled), "--port", "\(instance.webPort)", resource])
    }

    /// Enables or disables every resource carrying `label` in one call — not
    /// a loop over the group's individual resources.
    public func setEnabled(_ enabled: Bool, label: String, on instance: TiltInstance) async throws {
        _ = try await runner.run(binary, [subcommand(for: enabled), "--port", "\(instance.webPort)", "-l", label])
    }

    /// Enables or disables every resource on the instance.
    public func setEnabledForAll(_ enabled: Bool, on instance: TiltInstance) async throws {
        _ = try await runner.run(binary, [subcommand(for: enabled), "--port", "\(instance.webPort)", "--all"])
    }

    /// Deletes the resources a Tiltfile defines. Addressed by the Tiltfile's
    /// own path via `-f`, **not** by a running instance's port — `tilt down`
    /// has no `--port` flag. Running this against a live `tilt up` fights
    /// with that process; this method does not stop or otherwise terminate
    /// one, and callers must not use it as a substitute for that.
    ///
    /// Destructive, and the UI layer owns confirming that with the user —
    /// this method does not prompt. It does refuse to shell out with a path
    /// that would resolve against an arbitrary working directory: `path`
    /// must be non-empty and absolute.
    public func down(tiltfilePath: String) async throws {
        guard !tiltfilePath.isEmpty, tiltfilePath.hasPrefix("/") else {
            throw TiltActionError.invalidArgument(
                "down requires an absolute Tiltfile path, got: \"\(tiltfilePath)\""
            )
        }
        _ = try await runner.run(binary, ["down", "-f", tiltfilePath])
    }

    private func subcommand(for enabled: Bool) -> String {
        enabled ? "enable" : "disable"
    }
}
