// EnvCueShell — filesystem side effects for the shell integration.
//
// Owns shim install/uninstall (idempotent, anchored by `# >>> envcue >>>` /
// `# <<< envcue <<<`), the precmd hook template (builtin `read < file`, never `$(cat)`),
// atomic snapshot writes (tmp → fsync → rename, generation written last as the commit
// point, NFR-5), and generation management.
//
// Real types arrive in T3. This placeholder only establishes the module for T0.

import EnvCueCore

public enum EnvCueShell {
    /// Paired anchors used for idempotent shim injection/removal (FR-6).
    public static let beginAnchor = "# >>> envcue >>>"
    public static let endAnchor = "# <<< envcue <<<"
}
