# Gemstone V11 — Referral and Withdrawal Repair

## Fixes included

### Referral
- Recovers existing referral relationships from `referral_rewards`
- Shows users even when old `profiles.referred_by` data was missing
- Shows total referrals and active referrals
- Shows purchases and rewards per referred user

### Withdrawal
- Recreates the withdrawal RPC functions
- Minimum remains 120 points
- Shows current balance, pending points, and available points
- Prevents overlapping pending requests from exceeding available points
- Restores the missing Profile withdrawal JavaScript
- Restores the missing Admin withdrawal JavaScript
- Approval deducts points exactly once
- Rejection requires an admin note

## Installation

1. Run `v11_referral_withdrawal_repair.sql` once in Supabase SQL Editor.
2. Upload all files from this package to GitHub.
3. Preserve your real values in `config.js`.
4. Wait for GitHub Pages deployment.
5. Refresh with Ctrl + Shift + R.

Do not rerun the original reset schema.
