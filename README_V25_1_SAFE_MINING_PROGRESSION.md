# Gemstone V25.1 — Safe Mining Progression

This package fixes the `progression_level is ambiguous` error and keeps the established V24 business functions unchanged.

## Preserved

- Membership purchases
- Wallet and GCash flow
- Referral commissions
- Redeem-points RPC and 24-hour timer
- Withdrawals
- Admin controls and logs

## Mining rules

- The first active gemstone is available to every regular player.
- Mining creates materials used to unlock the next gemstone.
- Materials are deducted during unlocking.
- Each mine has a 60-minute cooldown.
- A purchased membership bypasses the material requirement for that gemstone.
- Existing memberships are recognized automatically and can mine immediately.

## Installation

1. Run `v25_1_safe_mining_progression.sql` in Supabase SQL Editor.
2. Upload the website files to GitHub Pages.
3. Keep your existing `config.js`.
4. Fully close and reopen the APK or browser.
