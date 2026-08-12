# swift-openapi-generator

| Fact | Value |
|---|---|
| **Repo** | https://github.com/swiftlang/swift-openapi-generator |
| **Latest version** | 1.x (2026-08, re-verify) |
| **License** | Apache-2.0 (Swift license) |
| **Platforms** | macOS (CLI) / build plugin |
| **Apple Silicon status** | ✅ Native |

## What it is

Generates Swift client/server code from OpenAPI documents.

## Why it matters for Qwave

- Mullvad's API is simple enough to hand-roll (already done in
      `MullvadAPIClient`); a generated client would only pay off if we add
      many endpoints or additional services.

## Apple Silicon notes

- Runs on URLSession transports — routing-safe.

## Adoption sketch

- Optional: regenerate the Mullvad client from their OpenAPI spec if it
      is published and stable.

## Risks

- Generator churn; Mullvad may not publish an OpenAPI spec at all.

## Verdict: Assess
