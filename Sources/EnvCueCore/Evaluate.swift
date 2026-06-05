// Evaluation (T1.3). The single source of truth for `base < scene` layering
// (design §4). Pure function: it reads no process environment, so identical inputs
// always produce identical output (NFR-3, invariant #1).

public extension EnvCueCore {
    /// Resolve `base` overlaid by an optional `scene`.
    ///
    /// - base entries seed the result, tagged `source: .base`;
    /// - a scene `plain`/`secret` entry overrides the same-named base var, tagged with
    ///   the scene as source;
    /// - a scene `unset` entry removes the var entirely.
    ///
    /// v1 scene mutual-exclusion lives at the call layer (only one scene is ever passed);
    /// relaxing to stacked scenes later changes only this overlay loop, not the model.
    static func evaluate(base: Layer, scene: Layer? = nil) -> ResolvedEnv {
        var resolved: [String: ResolvedVar] = [:]

        for entry in base.entries {
            resolved[entry.name] = ResolvedVar(entry: entry, source: .base)
        }

        if let scene {
            for entry in scene.entries {
                switch entry.kind {
                case .plain, .secret:
                    resolved[entry.name] = ResolvedVar(entry: entry, source: .scene(scene.name))
                case .unset:
                    resolved.removeValue(forKey: entry.name)
                }
            }
        }

        return ResolvedEnv(Array(resolved.values))
    }
}
