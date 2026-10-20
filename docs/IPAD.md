# iPad browser layout

Qwave 2.0.6 enables native iPhone and iPad device families. All four iPad orientations are declared; the shell follows the available window width rather than a device-name check.

- At 1,000 points and wider, a collapsible 244-point tab sidebar shares the window with the page.
- Below that, horizontally scrolling tabs keep page space available.
- Below 700 points, or with accessibility text sizes, address and navigation controls use separate rows.
- Controls have 44-point touch targets, tab selection uses accessible buttons, and the active tab is identified for VoiceOver.
- New tabs use the animated Memory Wave start page with responsive search and saved-page suggestions. The default first tab uses that page too; an explicitly configured homepage is preserved.
- Remember this page saves its title and URL in the existing encrypted, local Memory Wave store. Suggestions reopen saved URLs. Browsing is not captured automatically, and this UI does not claim to generate AI answers.
- The start-page message bridge accepts only the active main frame at qwave://start. Settings include a confirmation before clearing saved waves.
- Settings use a single navigation stack inside their sheet.

The shell now starts the initial pending navigation after installing its delegates, identifies page views by tab ID, and ignores background-tab navigation callbacks when updating the active address/loading controls.

Validation records and simulator screenshots are maintained outside the repository. Physical-device multitasking, VoiceOver and TestFlight acceptance remain separate from successful local builds. This change does not enable the pending Apple browser/passkey entitlement.
