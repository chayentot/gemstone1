# Gemstone Membership — GitHub Pages + Supabase

This version is a real static website for GitHub Pages. It contains `index.html`, so GitHub will show the website instead of displaying this README.

## What it includes

- Home, Membership, and Profile pages
- Supabase email/password registration and login
- Ten gemstone plans
- Wallet balance and demo cash-in
- Wallet-funded purchases
- Points balance and transaction history
- Secure PostgreSQL purchase and redemption functions
- 24-hour redemption timer
- No accumulation of missed days: the next timer begins when the user claims
- Row Level Security

## Setup

### 1. Create the database

Open your Supabase project.

1. Go to **SQL Editor**
2. Create a new query
3. Copy all of `supabase_schema.sql`
4. Click **Run**

### 2. Add your browser configuration

Open `config.js` and replace:

```js
window.LAUNCHBOARD_CONFIG = {
  supabaseUrl: "YOUR_SUPABASE_URL",
  supabaseKey: "YOUR_SUPABASE_PUBLISHABLE_KEY"
};
```

Use values from **Supabase Dashboard → Project Settings → API**.

Use only the **Project URL** and **publishable/anon key**. Never add the service-role key to this repository.

### 3. Supabase authentication settings

In Supabase go to **Authentication → URL Configuration**.

Add your GitHub Pages address as the Site URL, for example:

```text
https://YOUR_USERNAME.github.io/gemstones/
```

You can disable email confirmation during testing in **Authentication → Providers → Email**, or leave it enabled and confirm each registration email.

### 4. Upload to GitHub

Upload the contents of this folder to the repository root. `index.html` must be in the same top-level folder as `README.md`.

Expected structure:

```text
index.html
membership.html
profile.html
config.js
supabase_schema.sql
css/style.css
js/common.js
js/home.js
js/membership.js
js/profile.js
```

Do not upload an outer folder that contains these files. Upload the files themselves.

### 5. Enable GitHub Pages

Go to:

**Repository → Settings → Pages → Build and deployment**

Choose:

- Source: **Deploy from a branch**
- Branch: **main**
- Folder: **/(root)**

Save, wait a few minutes, then reload the Pages URL.

## Important

`demo_cash_in` creates test money without a payment. Remove it before production and replace it with a verified payment webhook or an admin-approved cash-in workflow.

Before accepting real money or promising financial returns, obtain appropriate legal and payment-provider advice in the countries where the platform operates.
