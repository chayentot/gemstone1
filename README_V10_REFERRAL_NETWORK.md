# Gemstone V10 — Referral Network

This update adds:

- Total referral count
- Total purchases made by referred users
- Total referral rewards earned
- Private list of users under the logged-in user's referral code
- Date each referred user joined
- Number of gemstone purchases per referred user
- Total purchased amount per referred user
- Total commission generated per referred user

## Install

1. Run `v10_referral_network_upgrade.sql` once in Supabase SQL Editor.
2. Upload the updated website files to GitHub.
3. Replace `profile.html`, `profile.js`, and `style.css`.
4. Refresh the website with Ctrl + Shift + R.

The referral list is private. Each logged-in user can retrieve only their own direct referrals through protected database functions.
