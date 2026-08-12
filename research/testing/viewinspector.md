# ViewInspector

| Fact | Value |
|---|---|
| **Repo** | https://github.com/nalexn/ViewInspector |
| **Latest version** | 0.10.x (2026-08, re-verify) |
| **License** | MIT |
| **Platforms** | macOS / iOS |
| **Apple Silicon status** | ✅ Native |

## What it is

Introspects SwiftUI view hierarchies for unit testing.

## Why it matters for Qwave

- Qwave's SwiftUI panes (SettingsWindow, ShieldsPopoverView) currently
      have zero view tests; ViewInspector is the pragmatic way to cover
      toggles and pickers.

## Apple Silicon notes

- Pure Swift.

## Adoption sketch

- Trial on the Settings panes; drop if it fights AppKit hosting.

## Risks

- Fragile against SwiftUI internals across OS updates.

## Verdict: Trial
