[2026-03-13 14:29] - Updated by Junie
{
    "TYPE": "correction",
    "CATEGORY": "initial screen refresh",
    "EXPECTATION": "On opening an existing terminal session, the current terminal view should appear immediately without requiring an extra keypress.",
    "NEW INSTRUCTION": "WHEN opening an existing terminal session THEN immediately render the current screen without user input"
}

[2026-03-13 15:23] - Updated by Junie
{
    "TYPE": "correction",
    "CATEGORY": "browser rendering",
    "EXPECTATION": "The terminal view should not appear distorted in the browser; it must render at correct dimensions on open and resize.",
    "NEW INSTRUCTION": "WHEN initializing terminal in browser THEN set cols/rows precisely before first render"
}

[2026-03-13 15:28] - Updated by Junie
{
    "TYPE": "correction",
    "CATEGORY": "dependency version mismatch",
    "EXPECTATION": "The Flutter client should use a published xterm version so pub get/build resolves successfully (e.g., ^4.0.x, not ^4.1.0 which is unavailable).",
    "NEW INSTRUCTION": "WHEN updating xterm in pubspec THEN verify on pub.dev and use latest 4.0.x"
}

