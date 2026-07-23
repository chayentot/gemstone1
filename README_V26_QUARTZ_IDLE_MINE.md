# Gemstone V26 — Quartz Idle Mine

V26 starts the game mechanics with a free Quartz mine.

## Quartz mechanics

- Level 1 produces 1 Quartz every second.
- Level 1 storage capacity is 3,600 Quartz.
- Production continues while the player is offline.
- Production stops when storage reaches maximum capacity.
- The player presses Collect Quartz to move production into the material balance.
- Every upgrade adds 1 Quartz per second.
- Every upgrade adds 3,600 storage capacity.
- Upgrade cost is 1,000 × current level² Quartz.

Examples:

- Level 1 → Level 2 costs 1,000 Quartz.
- Level 2 → Level 3 costs 4,000 Quartz.
- Level 3 → Level 4 costs 9,000 Quartz.

## Security

All production, capacity, collection, and upgrades are calculated using Supabase server time. Client clock changes and repeated button taps cannot create extra materials.

## Layout

The Home page now uses a vertical mining-valley path inspired by the supplied reference. Quartz is the active building and Amethyst appears as the next locked area.

## Installation

1. Run `v26_quartz_idle_mine.sql` in Supabase SQL Editor.
2. Upload the V26 website files to GitHub Pages.
3. Preserve your working `config.js`.
4. Fully close and reopen the APK or browser.

Existing wallet, membership, referral, withdrawal, and redemption systems remain unchanged.
