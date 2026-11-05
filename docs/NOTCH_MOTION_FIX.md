# Notch opening and motion fixes — 5 November 2026

Scope: HeyNotch 2.8.1 (273), Preview 2. The report concerned the installed Mac app, not the marketing website.

## Findings and changes

| Before | After | Evidence / reason |
| --- | --- | --- |
| The closed shelf's transparent drop target covered the full native panel; the external detector used the future 640 × 190 open area. | Activation uses the closed notch, with an optional 24-point approach margin beside and below it. | A point 132 points below the screen top was inside the former area and is outside the closed target. Tests cover both axes and offset displays. |
| A queued drag entry could open after release, exit, or replacement of the detector. | Delivery rechecks its entry token, detector, current pointer, pressed button, pasteboard and settings. | Thirteen drag-policy regressions exercise stale entries, release, movement, content changes, internal task moves and teardown. |
| The delayed hover action trusted the earlier hover callback. | It checks the current pointer against the visible notch again, and rechecks the preference/menu/first-launch state. | Geometry tests reject a pointer that moved away even if no exit callback was delivered. The current-pointer check is at the action boundary. |
| Closing a task board immediately reduced the native window to 640 × 210, while the outgoing SwiftUI content was still animating. | The hosting canvas remains large enough for the maximum task board. Hover and drop activation use separate, smaller geometry. Identical native window frames are not reapplied. | Sizing tests cover every page, row counts, compact displays and invalid dimensions. |
| Separate state, size, content-scale and per-gesture animations could use different curves for the same change. | One state/size transition owns the notch. Content fades; gesture samples track input directly and settle on release. Reduce Motion suppresses decorative scaling. | Source review confirms the duplicate overrides and forced child zoom were removed. Perceived smoothness is not inferred from a unit test. |
| Hidden tab capsules shared the selected capsule's matched-geometry source ID. | Only the selected capsule supplies a source. | SwiftUI requires a unique inserted source for this effect. Tab selection also respects Reduce Motion. |
| Music bars restarted a reversing animation every 0.3 seconds from its prior target, with a forced 24 fps rate. | Each bar interpolates from its current presentation value to a committed model value, without reversing or a fixed frame-rate cap. Reduce Motion uses static bars. | Forty-four checks exercised the actual Core Animation properties and view lifecycle in an unshown native panel. Existing hidden, detached and released timer checks passed. |

## Verification and limits

The app logic suite passed **275 tests with zero failures and no skips**, including the existing MCP transport test, 13 new drag tests and eight new geometry/layout tests. The actual AppKit drag detector compiled in an isolated package as well. The music probe recorded 44 successful property/lifecycle assertions; it was not a rendered frame-rate benchmark.

This session did not have computer-use access for a live cursor/drag run of the rebuilt app. Actual WindowServer click-through outside the visible notch, SwiftUI tracking behavior during rapid real pointer motion, live drag delivery, and visually perceived smoothness remain manual acceptance checks. No measured FPS gain or universal production certification is claimed.

Small music, battery and system HUD notices remain independent of hover. They can intentionally appear after activity while the pointer is elsewhere; these changes address unintended expansion of the workspace and preserve those existing preferences.

To rerun the automated suite, build `MCPBridge` first, then run the `HeyNotch` scheme's tests with the locked package versions. The new tests are `NotchDragPolicyTests` and `NotchInteractionGeometryTests`.
