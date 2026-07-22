# Gemstone V25 — Mining Progression

V25 adds a factory-style gemstone progression system to the Home page.

## Regular players

- Quartz is unlocked automatically.
- Mining produces gemstone materials.
- Each next gemstone requires materials from the previous gemstone.
- Required materials are deducted when a mine is unlocked.
- Every unlocked mine can be used once per 60-minute mining cycle.

## Membership owners

- Any purchased gemstone is unlocked immediately.
- No material requirement is needed for that gemstone.
- The gemstone can be mined immediately after purchase.
- The first membership reward can also be redeemed immediately.
- Future membership rewards continue on the normal 24-hour cycle.

## Existing members

Existing purchased gemstones are automatically unlocked the first time the Home page loads.

## Installation

1. Run `v25_mining_progression.sql` in Supabase SQL Editor.
2. Upload the V25 website files to GitHub Pages.
3. Preserve your existing `config.js`.
4. Fully close and reopen the APK or browser.

## Important

Mining materials are progression resources. They do not directly increase wallet balance. Membership redemption remains the wallet-earning system.
