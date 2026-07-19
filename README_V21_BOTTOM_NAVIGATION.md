# Gemstone V21 — Bottom Mobile Navigation

This version moves the main cellphone navigation to the bottom of the screen.

## Mobile navigation

The following links are fixed at the bottom:

- Home
- Membership
- Profile

Logout remains in the top header beside the Gemstone branding.

## Other behavior

- The active page is highlighted.
- Bottom safe-area spacing is supported for modern phones.
- Page content receives extra bottom padding so it is not covered by the navigation.
- Desktop navigation remains unchanged.

## Installation

No new Supabase SQL is required.

1. Upload the V21 files to GitHub Pages.
2. Keep your existing `config.js`.
3. Refresh using Ctrl + Shift + R.
4. Close and reopen the APK or browser to clear cached CSS.

No APK rebuild is required because the app loads the live website.
