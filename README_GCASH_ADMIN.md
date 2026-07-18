# GCash cash-in and private admin upgrade

This package adds a manual GCash workflow to the existing GitHub Pages + Supabase website.

## User cash-in flow

1. User enters an amount.
2. The website creates a pending request.
3. The website shows your GCash account name, number, and exact amount.
4. User pays in the GCash app.
5. User submits the GCash reference number.
6. The request changes to `pending_review`.
7. The wallet is not credited yet.
8. An administrator checks GCash and approves or rejects it.
9. Approval credits the wallet exactly once.

## Setup

### 1. Configure GCash details

Edit `config.js`:

```js
gcashName: "YOUR GCash NAME",
gcashNumber: "09XXXXXXXXX"
```

These details are public because users must see them.

### 2. Upgrade Supabase

Run `gcash_admin_upgrade.sql` once in Supabase SQL Editor.

Do not rerun or replace your original gemstone tables.

### 3. Make your account an administrator

Register/login with your admin email, then run:

```sql
update public.profiles
set is_admin = true
where id = (
  select id from auth.users
  where email = 'YOUR_ADMIN_EMAIL@example.com'
);
```

Replace the email before running it.

### 4. Admin page

The admin page is:

```text
https://YOUR_USERNAME.github.io/YOUR_REPOSITORY/admin.html
```

It is intentionally absent from normal navigation, but the URL itself is not the security.
Supabase checks `profiles.is_admin` before returning requests or allowing approval.

### 5. Upload

Upload all files from this package, including:

- `admin.html`
- `admin.js`
- updated `profile.html`
- updated `profile.js`
- updated `style.css`
- updated `config.js`
- `gcash_admin_upgrade.sql`

## Safety

Never approve a request based only on the submitted reference number. Verify the reference, amount,
date, and payer in your actual GCash transaction history first.
