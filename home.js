const authGate = document.getElementById("authGate");
const dashboard = document.getElementById("dashboard");
const authMessage = document.getElementById("authMessage");
const homeMessage = document.getElementById("homeMessage");
let countdownTimer;
let miningCountdownTimer;

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
    const [profile, membershipsResult, miningResult] = await Promise.all([
      getProfile(session.user.id),
      db.from("user_memberships")
        .select("*, gemstones(*)")
        .eq("user_id", session.user.id)
        .order("purchased_at", { ascending: false }),
      db.rpc("get_home_mining_progress")
    ]);
    if (membershipsResult.error) throw membershipsResult.error;
    if (miningResult.error) throw miningResult.error;
    const memberships = membershipsResult.data || [];
    const miningProgress = miningResult.data || [];

    document.getElementById("summaryCards").innerHTML = `
      <article class="stat-card"><span>Wallet balance</span><strong>${money(profile.wallet_balance)}</strong></article>
      <article class="stat-card"><span>Available points</span><strong>${points(profile.points_balance)}</strong></article>
      <article class="stat-card"><span>Active gemstones</span><strong>${memberships.filter(x => x.status === "active").length}</strong></article>`;

    const miningGrid = document.getElementById("miningGemstones");
    miningGrid.innerHTML = miningProgress.map(mine => miningCard(mine)).join("");
    bindMiningButtons();
    startMiningCountdowns();

    const grid = document.getElementById("ownedGemstones");
    if (!memberships.length) {
      grid.innerHTML = '<div class="empty"><h2>No memberships yet</h2><p class="muted">You can still progress through free mining, or buy a membership to unlock a gemstone instantly.</p></div>';
    } else {
      grid.innerHTML = memberships.map(m => ownedCard(m)).join("");
      bindClaimButtons();
      startCountdowns();
    }
  } catch (error) {
    showMessage(homeMessage, error.message);
  }
}


function miningCard(mine) {
  const unlocked = Boolean(mine.is_unlocked);
  const owned = Boolean(mine.has_membership);
  const requirementMet = Number(mine.required_material_owned || 0) >= Number(mine.required_material_amount || 0);
  const canUnlock = !unlocked && requirementMet;
  const sourceLabel = owned
    ? "Membership unlocked"
    : unlocked
      ? (mine.unlock_source === "starter" ? "Starter mine" : "Materials unlocked")
      : "Locked";

  let requirement = "";
  if (!unlocked && Number(mine.progression_level) > 1) {
    requirement = `
      <div class="mine-requirement ${requirementMet ? "met" : ""}">
        <span>Required to unlock</span>
        <strong>${Number(mine.required_material_owned || 0).toLocaleString()} / ${Number(mine.required_material_amount || 0).toLocaleString()} ${escapeHtml(mine.required_material_name || "materials")}</strong>
      </div>`;
  }

  const action = unlocked
    ? `<button class="primary mine-btn" data-id="${mine.gemstone_id}">Mine now</button>`
    : `<button class="unlock-btn ${canUnlock ? "primary" : ""}" data-id="${mine.gemstone_id}" ${canUnlock ? "" : "disabled"}>
         ${canUnlock ? "Unlock mine" : "Need materials"}
       </button>`;

  return `
    <article class="mine-card ${unlocked ? "unlocked" : "locked"} ${owned ? "membership-unlocked" : ""}">
      <div class="mine-image">
        <img src="${escapeHtml(mine.image_url || gemImage(mine.gemstone_name))}"
             alt="${escapeHtml(mine.gemstone_name)} mine" loading="lazy">
        <span class="mine-level">Level ${mine.progression_level}</span>
        <span class="mine-lock-badge">${unlocked ? (owned ? "★ MEMBER" : "OPEN") : "🔒 LOCKED"}</span>
      </div>
      <div class="mine-body">
        <div class="mine-title">
          <h3>${escapeHtml(mine.gemstone_name)} Mine</h3>
          <small>${sourceLabel}</small>
        </div>
        <div class="mine-stats">
          <div><span>Materials</span><strong>${Number(mine.materials_owned || 0).toLocaleString()}</strong></div>
          <div><span>Per mine</span><strong>+${Number(mine.material_yield || 0).toLocaleString()}</strong></div>
        </div>
        ${requirement}
        <p class="mine-status ${unlocked ? "" : "locked"}"
           data-mine-next="${unlocked ? (mine.next_mine_at || "") : ""}">
          ${unlocked ? "Checking mine…" : "Unlock the mine to begin"}
        </p>
        ${action}
        ${!unlocked ? '<a class="mine-membership-link" href="membership.html">Buy membership to open instantly</a>' : ""}
      </div>
    </article>`;
}

function startMiningCountdowns() {
  clearInterval(miningCountdownTimer);

  const update = () => {
    document.querySelectorAll("[data-mine-next]").forEach(status => {
      const button = status.parentElement.querySelector(".mine-btn");
      if (!button) return;

      if (!status.dataset.mineNext) {
        status.textContent = "Ready to mine";
        status.classList.remove("waiting");
        button.disabled = false;
        return;
      }

      const seconds = Math.floor((new Date(status.dataset.mineNext) - new Date()) / 1000);
      if (seconds <= 0) {
        status.textContent = "Ready to mine";
        status.classList.remove("waiting");
        button.disabled = false;
      } else {
        const h = Math.floor(seconds / 3600);
        const m = Math.floor((seconds % 3600) / 60);
        const s = seconds % 60;
        status.textContent = h > 0
          ? `Mine ready in ${h}h ${m}m ${s}s`
          : `Mine ready in ${m}m ${s}s`;
        status.classList.add("waiting");
        button.disabled = true;
      }
    });
  };

  update();
  miningCountdownTimer = setInterval(update, 1000);
}

function bindMiningButtons() {
  document.querySelectorAll(".mine-btn").forEach(button => {
    button.addEventListener("click", async () => {
      if (button.dataset.busy === "true") return;

      const task = async () => {
        const { data, error } = await db.rpc("mine_gemstone", {
          p_gemstone_id: button.dataset.id
        });
        if (error) {
          showMessage(homeMessage, error.message);
          showGlobalToast?.(error.message, "error");
          return;
        }

        const amount = Number(data || 0);
        const text = `Mining complete. You collected ${amount.toLocaleString()} materials.`;
        showMessage(homeMessage, text, true);
        showGlobalToast?.(text, "success");
        await render();
      };

      if (window.runButtonTask) {
        await runButtonTask(button, task, "Mining gemstone…");
      } else {
        button.disabled = true;
        await task();
      }
    });
  });

  document.querySelectorAll(".unlock-btn:not(:disabled)").forEach(button => {
    button.addEventListener("click", async () => {
      if (!confirm("Use the required materials to unlock this gemstone mine?")) return;

      const task = async () => {
        const { error } = await db.rpc("unlock_gemstone_with_materials", {
          p_gemstone_id: button.dataset.id
        });
        if (error) {
          showMessage(homeMessage, error.message);
          showGlobalToast?.(error.message, "error");
          return;
        }

        showMessage(homeMessage, "Gemstone mine unlocked. You can mine immediately.", true);
        showGlobalToast?.("Mine unlocked successfully.", "success");
        await render();
      };

      if (window.runButtonTask) {
        await runButtonTask(button, task, "Unlocking mine…");
      } else {
        button.disabled = true;
        await task();
      }
    });
  });
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
