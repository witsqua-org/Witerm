# Language and Appearance

**Language.** The apps use the system's preferred language: English (the fallback) or Simplified Chinese. There is no in-app language picker. After changing the system language, relaunch the app. A per-app language set in system settings takes precedence.

**Appearance.** The apps and their terminals follow system light/dark mode. You can still adjust terminal text size, enhanced contrast, and VoiceOver output notifications ([Terminal experience](terminal-experience.md)).

## Translating

Strings live in `apps/apple/Sources/Resources/`:

- `Localizable.xcstrings`: interface text, errors, and accessibility labels and hints
- `InfoPlist.xcstrings`: the local-network permission prompt

**Rules.**
- Use English source keys.
- Use SwiftUI's localized text for literal labels. Use `String(localized:bundle:)` for strings built in code and for AppKit or UIKit accessibility properties.
- Keep format placeholders the same in every language.
- Never translate hostnames, user-entered names, paths, protocol identifiers, terminal output, or keyboard input.

Project documentation is in English.

## Testing

- `WitermMacTerminalTests` and `WitermiOSTerminalTests` check:
  - the compiled catalogs and the English fallback
  - accessibility text and the permission prompt
  - that an appearance change keeps terminal contents
- `WitermiOSUITests/SystemLanguageTests` launches in English, Simplified Chinese, and an unsupported language (which should fall back to English). Run it on an existing simulator with parallel testing off:

  ```sh
  -only-testing:WitermiOSUITests/SystemLanguageTests
  ```

Tests that check Chinese text launch with `-AppleLanguages (zh-Hans)`. A normal launch never overrides the system language.
