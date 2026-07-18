# Gemstone V15 — Admin User Controls

This version adds secure controls to the **Registered users** section of the admin page.

## Features

For every normal user, an administrator can:

- Add money to the wallet
- Deduct money from the wallet
- Permanently delete the account for illegal or abusive activity

Administrator accounts are protected.

## Installation

1. Open Supabase → SQL Editor.
2. Run `v15_admin_user_controls.sql` once.
3. Upload all updated website files to GitHub Pages.
4. Keep your existing values in `config.js`.
5. Refresh with Ctrl + Shift + R.

## Safety

Wallet changes require a reason, cannot create a negative balance, are limited to ₱100,000 per operation, and are permanently audited.

Account deletion requires a detailed reason and typing `DELETE`. Administrators and accounts with pending financial requests are protected. Deletion is permanent.
