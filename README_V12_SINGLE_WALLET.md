# Gemstone V12 — Single Wallet

V12 removes the separate available-points balance from the user interface.

## New balance flow

- Add Funds → Wallet balance
- Gemstone redemption → Wallet balance
- Referral commission → Wallet balance
- Withdrawal → Deducted from wallet balance after admin approval

## Conversion

Existing and future rewards use:

```text
1 reward point = ₱1.00
```

Existing `points_balance` values are transferred to `wallet_balance` once by the migration.

## Install

1. Run `v12_single_wallet_upgrade.sql` once in Supabase SQL Editor.
2. Upload the complete website package to GitHub.
3. Preserve your actual Supabase and GCash values in `config.js`.
4. Wait for GitHub Pages deployment.
5. Refresh with Ctrl + Shift + R.

## Minimum withdrawal

The minimum withdrawal is now ₱120 from the wallet.
