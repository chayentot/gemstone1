# Gemstone V16 — Admin Gemstone Management

This version includes all V15 user controls and adds **Gemstone Management** to the admin page.

## Admin capabilities

- Add a new gemstone membership
- Edit gemstone name and emoji
- Edit membership price
- Edit reward per claim
- Edit maximum claims
- Edit description
- Set an image URL or local image filename
- Activate or deactivate a plan

Inactive plans disappear from the membership purchase page but remain in the database so existing memberships are not damaged.

## Installation

1. Run `v16_admin_gemstone_management.sql` in Supabase SQL Editor.
2. Upload the updated website files to GitHub Pages.
3. Preserve your existing `config.js`.
4. Refresh with Ctrl + Shift + R.

## Existing memberships

Changing a gemstone affects future purchases. Existing purchased memberships retain their original purchase price, reward, and maximum claims because those values are saved in `user_memberships` at purchase time.

## APK

The APK loads the live GitHub Pages website, so the new admin controls and gemstone values appear automatically after the website deployment.
