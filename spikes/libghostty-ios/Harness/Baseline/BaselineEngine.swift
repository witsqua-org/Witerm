#if ENGINE_NONE
import UIKit

/// The harness with no terminal engine, for binary-size and memory baselines.
let engineBuildName = "baseline"

@MainActor func makeEngine(_ config: EngineConfig) -> TerminalEngine? { nil }

func makeHeadless(cols: Int, rows: Int, scrollback: Int) -> HeadlessParser? { nil }
#endif
