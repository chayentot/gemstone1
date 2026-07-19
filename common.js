(() => {
  const cfg = window.LAUNCHBOARD_CONFIG || {};
  if (!cfg.supabaseUrl || !cfg.supabaseKey ||
      cfg.supabaseUrl.includes("YOUR_") || cfg.supabaseKey.includes("YOUR_")) {
    document.body.insertAdjacentHTML("afterbegin",
      '<div style="padding:12px;background:#fff3cd;color:#7a5200;text-align:center;font-weight:700">Open <code>config.js</code> and add your Supabase URL and publishable/anon key.</div>');
  }

  window.db = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey);

  window.money = value =>
    new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value || 0));

  window.points = value =>
    new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(Number(value || 0));

  window.escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;"
  }[c]));

  window.requireUser = async () => {
    const { data: { session } } = await window.db.auth.getSession();
    if (!session) {
      window.location.href = "index.html";
      return null;
    }
    return session.user;
  };

  window.getProfile = async userId => {
    const { data, error } = await window.db
      .from("profiles")
      .select("*")
      .eq("id", userId)
      .single();
    if (error) throw error;
    return data;
  };


  window.gemImage = name => {
    const file = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-");
    return `${file}.webp`;
  };

  window.showMessage = (element, text, success = false) => {
    element.textContent = text || "";
    element.classList.toggle("success", success);
  };

  document.getElementById("logoutBtn")?.addEventListener("click", async () => {
    await window.db.auth.signOut();
    window.location.href = "index.html";
  });
})();


// =========================================================
// V23 shared mobile interaction helpers
// =========================================================
window.setGlobalLoading = function setGlobalLoading(active, text = "Please wait…") {
  const overlay = document.getElementById("globalLoadingOverlay");
  const label = document.getElementById("globalLoadingText");
  if (!overlay) return;
  if (label) label.textContent = text;
  overlay.classList.toggle("hidden", !active);
  overlay.setAttribute("aria-hidden", String(!active));
};

window.showGlobalToast = function showGlobalToast(message, type = "success") {
  const toast = document.getElementById("globalToast");
  if (!toast) return;
  toast.textContent = message;
  toast.className = `global-toast ${type}`;
  clearTimeout(window.__gemstoneToastTimer);
  window.__gemstoneToastTimer = setTimeout(() => {
    toast.classList.add("hidden");
  }, 3200);
};

window.runButtonTask = async function runButtonTask(button, task, loadingText = "Please wait…") {
  if (!button || button.dataset.busy === "true") return;
  button.dataset.busy = "true";
  button.disabled = true;
  button.classList.add("is-loading");
  setGlobalLoading(true, loadingText);
  try {
    return await task();
  } finally {
    setGlobalLoading(false);
    button.classList.remove("is-loading");
    button.disabled = false;
    button.dataset.busy = "false";
  }
};

(function setupMobileKeyboardBehavior() {
  const viewport = window.visualViewport;
  if (!viewport) return;

  const update = () => {
    const keyboardLikelyOpen = window.innerHeight - viewport.height > 140;
    document.body.classList.toggle("keyboard-open", keyboardLikelyOpen);
  };

  viewport.addEventListener("resize", update);
  viewport.addEventListener("scroll", update);
  update();
})();

document.addEventListener("click", event => {
  const button = event.target.closest("button, .primary");
  if (!button || button.disabled || button.dataset.busy === "true") return;
  if (button.type === "submit" || button.classList.contains("primary")) {
    button.style.webkitTapHighlightColor = "transparent";
  }
});
