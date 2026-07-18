function openProfilePanel(panelId) {
  document.querySelectorAll(".profile-panel").forEach(panel => {
    panel.classList.toggle("active-panel", panel.id === panelId);
  });
  document.querySelectorAll(".profile-action").forEach(button => {
    button.classList.toggle("active", button.dataset.panel === panelId);
  });
  sessionStorage.setItem("profileActivePanel", panelId);
}

document.querySelectorAll(".profile-action").forEach(button => {
  button.addEventListener("click", () => openProfilePanel(button.dataset.panel));
});

const rememberedPanel = sessionStorage.getItem("profileActivePanel");
if (rememberedPanel && document.getElementById(rememberedPanel)) {
  openProfilePanel(rememberedPanel);
}

const profileMessage = document.getElementById("profileMessage");
const withdrawalMessage = document.getElementById("withdrawalMessage");
const cfg = window.LAUNCHBOARD_CONFIG || {};
let currentUser;

function statusBadge(status) {
  const labels = {
    awaiting_reference: "Awaiting reference",
    pending_review: "Pending review",
    approved: "Approved",
    rejected: "Rejected",
    cancelled: "Cancelled"
  };
  return `<span class="request-status ${escapeHtml(status)}">${escapeHtml(labels[status] || status)}</span>`;
}

function peso(value) {
  return `₱${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

async function loadProfile() {
  currentUser = await requireUser();
  if (!currentUser) return;
  document.getElementById("profileEmail").textContent = currentUser.email;

  try {
    const [
      profile,
      walletResult,
      memberResult,
      cashInResult,
      rewardResult,
      withdrawalResult,
      referralSummaryResult,
      referralUsersResult,
      withdrawalBalanceResult
    ] = await Promise.all([
      getProfile(currentUser.id),
      db.from("wallet_transactions").select("*").eq("user_id", currentUser.id)
        .order("created_at", { ascending: false }).limit(30),
      db.from("user_memberships").select("id,status").eq("user_id", currentUser.id),
      db.from("cash_in_requests").select("*").eq("user_id", currentUser.id)
        .order("created_at", { ascending: false }).limit(30),
      db.from("referral_rewards").select("*").eq("referrer_id", currentUser.id)
        .order("created_at", { ascending: false }).limit(50),
      db.from("withdrawal_requests").select("*").eq("user_id", currentUser.id)
        .order("created_at", { ascending: false }).limit(50),
      db.rpc("get_my_referral_summary"),
      db.rpc("list_my_referrals"),
      db.rpc("get_my_withdrawal_balance")
    ]);

    for (const result of [
      walletResult, memberResult, cashInResult, rewardResult,
      withdrawalResult, referralSummaryResult, referralUsersResult, withdrawalBalanceResult
    ]) {
      if (result.error) throw result.error;
    }

    document.getElementById("profileSummary").innerHTML = `
      <article class="stat-card wallet-main-card">
        <span>Wallet balance</span>
        <strong>${peso(profile.wallet_balance)}</strong>
        <small>Cash-ins, gemstone rewards, and referral commissions</small>
      </article>
      <article class="stat-card">
        <span>Total memberships</span>
        <strong>${memberResult.data.length}</strong>
      </article>`;

    const withdrawalBalance = withdrawalBalanceResult.data?.[0] || {
      wallet_balance: profile.wallet_balance,
      pending_amount: 0,
      available_amount: profile.wallet_balance,
      minimum_amount: 120
    };
    const withdrawalInfo = document.getElementById("withdrawalBalanceInfo");
    if (withdrawalInfo) {
      withdrawalInfo.innerHTML = `
        <span>Wallet: <strong>${peso(withdrawalBalance.wallet_balance)}</strong></span>
        <span>Pending: <strong>${peso(withdrawalBalance.pending_amount)}</strong></span>
        <span>Available: <strong>${peso(withdrawalBalance.available_amount)}</strong></span>`;
    }

    document.getElementById("withdrawalRequests").innerHTML =
      withdrawalResult.data.length
        ? withdrawalResult.data.map(row => `
          <tr>
            <td>${new Date(row.created_at).toLocaleString()}</td>
            <td>${peso(row.amount)}</td>
            <td>${peso(row.processing_fee)}</td>
            <td><strong>${peso(row.net_amount)}</strong></td>
            <td><strong>${escapeHtml(row.gcash_name)}</strong><small class="block muted">${escapeHtml(row.gcash_number)}</small></td>
            <td>${statusBadge(row.status)}</td>
            <td>${escapeHtml(row.admin_note || "")}</td>
          </tr>`).join("")
        : '<tr><td colspan="7">No withdrawal requests yet.</td></tr>';

    document.getElementById("myReferralCode").textContent = profile.referral_code || "—";
    const referralUrl = new URL("index.html", window.location.href);
    referralUrl.searchParams.set("ref", profile.referral_code || "");
    document.getElementById("myReferralLink").value = referralUrl.href;

    if (profile.referred_by) {
      document.getElementById("applyReferralForm").innerHTML =
        '<p class="status">A referral code has already been applied to your account.</p>';
    }

    const summary = referralSummaryResult.data?.[0] || {};
    document.getElementById("referralSummary").innerHTML = `
      <article class="referral-stat"><span>Total referrals</span><strong>${Number(summary.referral_count || 0).toLocaleString()}</strong></article>
      <article class="referral-stat"><span>Active referrals</span><strong>${Number(summary.active_referral_count || 0).toLocaleString()}</strong></article>
      <article class="referral-stat"><span>Total referred purchases</span><strong>${peso(summary.total_referred_purchase_amount)}</strong></article>
      <article class="referral-stat"><span>Total referral rewards</span><strong>${peso(summary.total_rewards)}</strong></article>`;

    document.getElementById("referralUsers").innerHTML =
      referralUsersResult.data?.length
        ? referralUsersResult.data.map(row => `
          <tr>
            <td>
              <strong>${escapeHtml(row.full_name || "Unnamed member")}</strong>
              <small class="block muted">${escapeHtml(row.referral_status || "Registered")}</small>
            </td>
            <td>${row.joined_at ? new Date(row.joined_at).toLocaleDateString() : "—"}</td>
            <td>${Number(row.purchases_count || 0).toLocaleString()}</td>
            <td>${peso(row.total_purchase_amount)}</td>
            <td>${peso(row.total_reward_generated)}</td>
          </tr>`).join("")
        : '<tr><td colspan="5">No users have registered under your referral link yet.</td></tr>';

    document.getElementById("referralRewards").innerHTML =
      rewardResult.data.length
        ? rewardResult.data.map(row => `
          <tr>
            <td>${new Date(row.created_at).toLocaleString()}</td>
            <td>${peso(row.purchase_amount)}</td>
            <td>${Number(row.reward_rate) * 100}%</td>
            <td>${peso(row.reward_amount)}</td>
          </tr>`).join("")
        : '<tr><td colspan="4">No referral rewards yet.</td></tr>';

    document.getElementById("cashInRequests").innerHTML =
      cashInResult.data.length
        ? cashInResult.data.map(row => `
          <tr>
            <td>${new Date(row.created_at).toLocaleString()}</td>
            <td>${peso(row.amount)}</td>
            <td>${escapeHtml(row.reference_number || "Not submitted")}</td>
            <td>${statusBadge(row.status)}</td>
            <td>${escapeHtml(row.admin_note || "")}</td>
          </tr>`).join("")
        : '<tr><td colspan="5">No cash-in requests yet.</td></tr>';

    document.getElementById("walletTransactions").innerHTML =
      walletResult.data.length
        ? walletResult.data.map(row => `
          <tr><td>${new Date(row.created_at).toLocaleString()}</td>
          <td>${escapeHtml(row.type)}</td><td>${peso(row.amount)}</td>
          <td>${escapeHtml(row.description || "")}</td></tr>`).join("")
        : '<tr><td colspan="4">No wallet activity yet.</td></tr>';
  } catch (error) {
    showMessage(profileMessage, error.message);
    showMessage(withdrawalMessage, error.message);
  }
}

document.getElementById("cashInForm")?.addEventListener("submit", async event => {
  event.preventDefault();
  const amount = Number(document.getElementById("cashInAmount").value);
  if (!Number.isFinite(amount) || amount < 50 || amount > 100000) {
    return showMessage(profileMessage, "Enter an amount from ₱50 to ₱100,000.");
  }
  const { data, error } = await db.rpc("create_cash_in_request", { p_amount: amount });
  if (error) return showMessage(profileMessage, error.message);

  document.getElementById("cashInRequestId").value = data;
  document.getElementById("paymentAmount").textContent = peso(amount);
  document.getElementById("gcashName").textContent = cfg.gcashName || "Configure gcashName";
  document.getElementById("gcashNumber").textContent = cfg.gcashNumber || "Configure gcashNumber";
  document.getElementById("paymentInstructions").classList.remove("hidden");
  showMessage(profileMessage, "Request created. Pay through GCash, then submit the reference number.", true);
  await loadProfile();
});

document.getElementById("referenceForm")?.addEventListener("submit", async event => {
  event.preventDefault();
  const requestId = document.getElementById("cashInRequestId").value;
  const reference = document.getElementById("referenceNumber").value.trim().replace(/\s+/g, "");
  if (!requestId) return showMessage(profileMessage, "Create a cash-in request first.");
  if (reference.length < 6) return showMessage(profileMessage, "Enter a valid GCash reference number.");

  const { error } = await db.rpc("submit_cash_in_reference", {
    p_request_id: requestId,
    p_reference_number: reference
  });
  if (error) return showMessage(profileMessage, error.message);

  event.target.reset();
  document.getElementById("paymentInstructions").classList.add("hidden");
  document.getElementById("cashInForm").reset();
  showMessage(profileMessage, "Reference submitted for administrator verification.", true);
  await loadProfile();
});

function updateWithdrawalFeePreview() {
  const input = document.getElementById("withdrawalAmount");
  const preview = document.getElementById("withdrawalFeePreview");
  if (!input || !preview) return;

  const gross = Math.max(0, Number(input.value) || 0);
  const fee = Math.round(gross * 0.06 * 100) / 100;
  const net = Math.max(0, Math.round((gross - fee) * 100) / 100);

  preview.innerHTML = `
    <span>Requested <strong>${peso(gross)}</strong></span>
    <span>Processing fee (6%) <strong>−${peso(fee)}</strong></span>
    <span>You receive <strong>${peso(net)}</strong></span>`;
}

document.getElementById("withdrawalAmount")?.addEventListener("input", updateWithdrawalFeePreview);
updateWithdrawalFeePreview();

document.getElementById("withdrawalForm")?.addEventListener("submit", async event => {
  event.preventDefault();

  const amount = Number(document.getElementById("withdrawalAmount").value);
  const gcashName = document.getElementById("withdrawalGcashName").value.trim();
  const gcashNumber = document.getElementById("withdrawalGcashNumber").value.trim();

  if (!Number.isFinite(amount) || amount < 120) {
    return showMessage(withdrawalMessage, "Minimum withdrawal is ₱120.");
  }
  if (gcashName.length < 2) {
    return showMessage(withdrawalMessage, "Enter the name registered in GCash.");
  }
  if (gcashNumber.replace(/\D/g, "").length < 10) {
    return showMessage(withdrawalMessage, "Enter a valid GCash mobile number.");
  }

  const submitButton = document.getElementById("withdrawalSubmitBtn");
  submitButton.disabled = true;
  showMessage(withdrawalMessage, "Submitting secure withdrawal request...");

  const requestKey = crypto.randomUUID();
  const { error } = await db.rpc("create_withdrawal_request", {
    p_amount: amount,
    p_gcash_name: gcashName,
    p_gcash_number: gcashNumber,
    p_request_key: requestKey
  });

  submitButton.disabled = false;
  if (error) return showMessage(withdrawalMessage, error.message);

  const fee = Math.round(amount * 0.06 * 100) / 100;
  const net = Math.round((amount - fee) * 100) / 100;
  event.target.reset();
  updateWithdrawalFeePreview();
  showMessage(withdrawalMessage, `Withdrawal submitted. Net GCash payout after 6% fee: ${peso(net)}.`, true);
  await loadProfile();
});

document.getElementById("copyReferralCode")?.addEventListener("click", async () => {
  await navigator.clipboard.writeText(document.getElementById("myReferralCode").textContent.trim());
  showMessage(profileMessage, "Referral code copied.", true);
});

document.getElementById("copyReferralLink")?.addEventListener("click", async () => {
  await navigator.clipboard.writeText(document.getElementById("myReferralLink").value);
  showMessage(profileMessage, "Referral link copied.", true);
});

document.getElementById("shareReferralLink")?.addEventListener("click", async () => {
  const link = document.getElementById("myReferralLink").value;
  if (navigator.share) {
    await navigator.share({ title: "Join Gemstone Membership", text: "Register using my referral link.", url: link });
  } else {
    await navigator.clipboard.writeText(link);
    showMessage(profileMessage, "Referral link copied.", true);
  }
});

document.getElementById("applyReferralForm")?.addEventListener("submit", async event => {
  event.preventDefault();
  const code = document.getElementById("referralCodeInput").value.trim();
  if (!code) return showMessage(profileMessage, "Enter a referral code.");

  const { error } = await db.rpc("apply_referral_code", { p_referral_code: code });
  if (error) return showMessage(profileMessage, error.message);

  showMessage(profileMessage, "Referral code applied successfully.", true);
  await loadProfile();
});

loadProfile();
