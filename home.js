const authGate = document.getElementById("authGate");
const dashboard = document.getElementById("dashboard");
const authMessage = document.getElementById("authMessage");
const homeMessage = document.getElementById("homeMessage");
let countdownTimer;
let quartzTicker;
let quartzState = null;

const REFERRAL_STORAGE_KEY = "gemstone_pending_referral";

function captureReferralLink() {
  const code = new URLSearchParams(window.location.search).get("ref");
  if (!code) return;
  const clean = code.trim().toUpperCase();
  if (!/^[A-Z0-9_-]{4,30}$/.test(clean)) return;
  localStorage.setItem(REFERRAL_STORAGE_KEY, clean);
  const registerTab = document.querySelector('[data-tab="register"]');
  registerTab?.click();
  showMessage(authMessage, `Referral ${clean} will be applied after registration.`, true);
}

async function applyPendingReferral() {
  const code = localStorage.getItem(REFERRAL_STORAGE_KEY);
  if (!code) return;
  const { data: { session } } = await db.auth.getSession();
  if (!session) return;

  const { data: profile, error: profileError } = await db
    .from("profiles")
    .select("referred_by, referral_code")
    .eq("id", session.user.id)
    .single();

  if (profileError || profile?.referred_by) {
    if (profile?.referred_by) localStorage.removeItem(REFERRAL_STORAGE_KEY);
    return;
  }

  if (String(profile?.referral_code || "").toUpperCase() === code) {
    localStorage.removeItem(REFERRAL_STORAGE_KEY);
    return;
  }

  const { error } = await db.rpc("apply_referral_code", { p_referral_code: code });
  if (!error) {
    localStorage.removeItem(REFERRAL_STORAGE_KEY);
    showMessage(homeMessage || authMessage, "Referral link applied successfully.", true);
  } else if (/already been applied/i.test(error.message || "")) {
    localStorage.removeItem(REFERRAL_STORAGE_KEY);
  }
}


document.querySelectorAll(".tab").forEach(button => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach(x => x.classList.remove("active"));
    button.classList.add("active");
    const login = button.dataset.tab === "login";
    document.getElementById("loginForm").classList.toggle("hidden", !login);
    document.getElementById("registerForm").classList.toggle("hidden", login);
    showMessage(authMessage, "");
  });
});

document.getElementById("loginForm").addEventListener("submit", async event => {
  event.preventDefault();
  showMessage(authMessage, "Signing in...");
  const { error } = await db.auth.signInWithPassword({
    email: document.getElementById("loginEmail").value.trim(),
    password: document.getElementById("loginPassword").value
  });
  if (error) return showMessage(authMessage, error.message);
  await applyPendingReferral();
  await render();
});

document.getElementById("registerForm").addEventListener("submit", async event => {
  event.preventDefault();
  showMessage(authMessage, "Creating your account...");
  const { data, error } = await db.auth.signUp({
    email: document.getElementById("registerEmail").value.trim(),
    password: document.getElementById("registerPassword").value,
    options: { data: {
      full_name: document.getElementById("registerName").value.trim(),
      pending_referral: localStorage.getItem(REFERRAL_STORAGE_KEY) || null
    } }
  });
  if (error) return showMessage(authMessage, error.message);
  if (!data.session) {
    showMessage(authMessage, "Account created. Check your email to confirm, then log in.", true);
    return;
  }
  await applyPendingReferral();
  await render();
});

async function render() {
  const { data: { session } } = await db.auth.getSession();
  const loggedIn = Boolean(session);
  authGate.classList.toggle("hidden", loggedIn);
  dashboard.classList.toggle("hidden", !loggedIn);
  document.getElementById("logoutBtn").classList.toggle("hidden", !loggedIn);
  if (!loggedIn) return;
  await applyPendingReferral();

  try {
    const [profile, membershipsResult, quartzResult] = await Promise.all([
      getProfile(session.user.id),
      db.from("user_memberships")
        .select("*, gemstones(*)")
        .eq("user_id", session.user.id)
        .order("purchased_at", { ascending: false }),
      db.rpc("get_quartz_mine")
    ]);
    if (membershipsResult.error) throw membershipsResult.error;
    if (quartzResult.error) throw quartzResult.error;
    const memberships = membershipsResult.data || [];
    quartzState = Array.isArray(quartzResult.data) ? quartzResult.data[0] : quartzResult.data;

    document.getElementById("summaryCards").innerHTML = `
      <article class="stat-card"><span>Wallet balance</span><strong>${money(profile.wallet_balance)}</strong></article>
      <article class="stat-card"><span>Quartz materials</span><strong>${Number(quartzState?.quartz_balance || 0).toLocaleString()}</strong></article>
      <article class="stat-card"><span>Mine level</span><strong>${Number(quartzState?.mine_level || 1)}</strong></article>`;

    renderQuartzMine();

    const grid = document.getElementById("ownedGemstones");
    if (!memberships.length) {
      grid.innerHTML = '<div class="empty"><h2>No memberships yet</h2><p class="muted">Your Quartz mine remains free. Memberships provide separate wallet rewards.</p></div>';
    } else {
      grid.innerHTML = memberships.map(m => ownedCard(m)).join("");
      bindClaimButtons();
      startCountdowns();
    }
  } catch (error) {
    showMessage(homeMessage, error.message);
  }
}


function currentQuartzStored() {
  if (!quartzState) return 0;

  const base = Number(quartzState.stored_quartz || 0);
  const rate = Number(quartzState.quartz_per_second || 1);
  const capacity = Number(quartzState.capacity || 3600);
  const calculatedAt = new Date(quartzState.calculated_at || Date.now()).getTime();
  const elapsedSeconds = Math.max(0, Math.floor((Date.now() - calculatedAt) / 1000));

  return Math.min(capacity, base + (elapsedSeconds * rate));
}

function renderQuartzMine() {
  clearInterval(quartzTicker);
  if (!quartzState) return;

  const level = Number(quartzState.mine_level || 1);
  const rate = Number(quartzState.quartz_per_second || level);
  const capacity = Number(quartzState.capacity || level * 3600);
  const balance = Number(quartzState.quartz_balance || 0);
  const upgradeCost = Number(quartzState.upgrade_cost || (1000 * level * level));

  document.getElementById("quartzLevelBadge").textContent = `Level ${level}`;
  document.getElementById("quartzRate").textContent = `${rate.toLocaleString()} / sec`;
  document.getElementById("quartzCapacity").textContent = capacity.toLocaleString();
  document.getElementById("quartzBalance").textContent = balance.toLocaleString();
  document.getElementById("quartzUpgradeInfo").textContent =
    `Level ${level + 1}: ${rate + 1}/sec, ${(capacity + 3600).toLocaleString()} capacity. Cost: ${upgradeCost.toLocaleString()} Quartz.`;

  const updateStorage = () => {
    const stored = currentQuartzStored();
    const percent = capacity > 0 ? Math.min(100, (stored / capacity) * 100) : 0;
    document.getElementById("quartzStorageText").textContent =
      `${Math.floor(stored).toLocaleString()} / ${capacity.toLocaleString()}`;
    document.getElementById("quartzStorageBar").style.width = `${percent}%`;

    const collectButton = document.getElementById("collectQuartzBtn");
    collectButton.disabled = stored < 1 || collectButton.dataset.busy === "true";
    collectButton.textContent = stored >= capacity
      ? "Collect — Storage full"
      : "Collect Quartz";
  };

  updateStorage();
  quartzTicker = setInterval(updateStorage, 1000);

  const collectButton = document.getElementById("collectQuartzBtn");
  const upgradeButton = document.getElementById("upgradeQuartzBtn");

  collectButton.onclick = async () => {
    const task = async () => {
      const { data, error } = await db.rpc("collect_quartz");
      if (error) throw error;

      const collected = Number(data || 0);
      showMessage(homeMessage, `Collected ${collected.toLocaleString()} Quartz.`, true);
      showGlobalToast?.(`+${collected.toLocaleString()} Quartz collected`, "success");
      await render();
    };

    try {
      if (window.runButtonTask) {
        await runButtonTask(collectButton, task, "Collecting Quartz…");
      } else {
        await task();
      }
    } catch (error) {
      showMessage(homeMessage, error.message);
      showGlobalToast?.(error.message, "error");
    }
  };

  upgradeButton.disabled = balance < upgradeCost;
  upgradeButton.textContent = balance >= upgradeCost
    ? `Upgrade for ${upgradeCost.toLocaleString()}`
    : `Need ${upgradeCost.toLocaleString()} Quartz`;

  upgradeButton.onclick = async () => {
    if (!confirm(`Spend ${upgradeCost.toLocaleString()} Quartz to upgrade the mine?`)) return;

    const task = async () => {
      const { data, error } = await db.rpc("upgrade_quartz_mine");
      if (error) throw error;

      const newLevel = Number(data || level + 1);
      showMessage(homeMessage, `Quartz Mine upgraded to level ${newLevel}.`, true);
      showGlobalToast?.(`Quartz Mine reached level ${newLevel}`, "success");
      await render();
    };

    try {
      if (window.runButtonTask) {
        await runButtonTask(upgradeButton, task, "Upgrading Quartz Mine…");
      } else {
        await task();
      }
    } catch (error) {
      showMessage(homeMessage, error.message);
      showGlobalToast?.(error.message, "error");
    }
  };
}

function ownedCard(m) {
  const gem = m.gemstones;
  const completed = m.status === "completed";
  return `
    <article class="gem-card">
      <div class="gem-top"><img src="${gemImage(gem.name)}" alt="${escapeHtml(gem.name)} gemstone" loading="lazy"></div>
      <div class="gem-body">
        <div class="gem-title"><h2>${escapeHtml(gem.name)}</h2><span class="price">${points(m.points_per_claim ?? gem.points_per_claim)} pts</span></div>
        <div class="meta">
          <div><span>Claims</span><strong>${Number(m.claims_completed ?? m.claims_made ?? 0)}/${m.max_claims}</strong></div>
          <div><span>Total earned</span><strong>${points(Number(m.claims_completed ?? m.claims_made ?? 0) * Number(m.points_per_claim ?? gem.points_per_claim ?? 0))}</strong></div>
        </div>
        <p class="status ${completed ? "" : "waiting"}" data-next="${m.next_redeem_at || ""}">
          ${completed ? "Membership completed" : "Checking timer…"}
        </p>
        <button class="primary claim-btn" data-id="${m.id}" ${completed ? "disabled" : ""}>Redeem points</button>
      </div>
    </article>`;
}

function startCountdowns() {
  clearInterval(countdownTimer);
  const update = () => {
    document.querySelectorAll("[data-next]").forEach(el => {
      if (!el.dataset.next) return;
      const seconds = Math.floor((new Date(el.dataset.next) - new Date()) / 1000);
      const button = el.parentElement.querySelector(".claim-btn");
      if (seconds <= 0) {
        el.textContent = "Ready to redeem";
        el.classList.remove("waiting");
        button.disabled = false;
      } else {
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        const s = seconds % 60;
        el.textContent = `Ready in ${h}h ${m}m ${s}s`;
        el.classList.add("waiting");
        button.disabled = true;
      }
    });
  };
  update();
  countdownTimer = setInterval(update, 1000);
}

function bindClaimButtons() {
  document.querySelectorAll(".claim-btn").forEach(button => {
    button.addEventListener("click", async () => {
      const membershipId = button.dataset.id;
      if (!membershipId || button.dataset.busy === "true") return;

      const redeemTask = async () => {
        showMessage(homeMessage, "Redeeming reward...");
        const { data, error } = await db.rpc("redeem_membership", {
          p_membership_id: membershipId
        });

        if (error) {
          const message = error.message || "Unable to redeem this reward.";
          showMessage(homeMessage, message);
          showGlobalToast?.(message, "error");
          return;
        }

        const reward = Number(data || 0);
        const successText = reward > 0
          ? `${money(reward)} was added to your wallet.`
          : "Reward redeemed successfully.";

        showMessage(homeMessage, successText, true);
        showGlobalToast?.(successText, "success");
        await render();
      };

      try {
        if (window.runButtonTask) {
          await runButtonTask(button, redeemTask, "Redeeming reward…");
        } else {
          button.disabled = true;
          await redeemTask();
        }
      } catch (error) {
        const message = error?.message || "Unexpected redemption error.";
        showMessage(homeMessage, message);
        showGlobalToast?.(message, "error");
      } finally {
        button.dataset.busy = "false";
      }
    });
  });
}

db.auth.onAuthStateChange(async () => {
  await applyPendingReferral();
  await render();
});
captureReferralLink();
render();
