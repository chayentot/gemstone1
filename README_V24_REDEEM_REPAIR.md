# Gemstone V24 — Redeem Points Repair

This version repairs the Redeem Points feature.

## Cause

The previous single-wallet redemption SQL referred to `claims_made`, but the membership table and website use `claims_completed`.

## Installation

1. Open Supabase → SQL Editor.
2. Run `v24_redeem_points_repair.sql`.
3. Upload the updated V24 website files to GitHub Pages.
4. Preserve your current `config.js`.
5. Close and reopen the APK or browser.

## Improvements

- Correct membership claim counter
- Secure row locking
- Prevents redemption before the timer expires
- Prevents claims beyond the maximum
- Adds the reward directly to wallet balance
- Records wallet and point transaction history
- Better loading, success, and error feedback
- Prevents repeated taps while processing
