# morsl — design direction

Applied ui-ux-pro-max: searched `food journal warm scrapbook`, then narrowed to
`personal food diary editorial`. The generated landing-page structure did not
fit this native app; no unverified output was persisted. The personal typography
pairing (Caveat / Quicksand), readable contrast, gentle depth, and adaptive Flutter
layout guidance were applicable. Native implementation uses LayoutBuilder,
SafeArea, labeled vector controls, and button alternatives to image gestures.

## Visual language

Warm paper #F8F5EE; ink #343B32; terracotta #AB5038; forest #465C43.
Sage, rose, sand, and cream backgrounds are canvas choices. Caveat belongs to the
wordmark and personal captions. Quicksand belongs to navigation, forms, and
metadata. Photographs are framed as paper prints with a small strip of tape.
Emojis are personal feeling values, not navigation icons. Native Material vector
icons provide a consistent family without another dependency.

## Interaction

History / Map / Drafts, with capture always available. Wide screens get a quiet
sidebar and a two- or three-column scrapbook. Small screens get one column and
bottom navigation. Cutout failure is an adjacent tool state, never a gate.
Saved originals and explicit fallback make every draft editable. No forced
onboarding or account requirement. Autosave and explicit Save memory coexist.
The default theme is light; dark mode is outside this beta’s visual scope.
