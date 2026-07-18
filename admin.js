const dashboard = document.getElementById("adminDashboard");
const denied = document.getElementById("adminDenied");
const adminMessage = document.getElementById("adminMessage");
const withdrawalAdminMessage = document.getElementById("withdrawalAdminMessage");
const cashDialog = document.getElementById("reviewDialog");
const withdrawalDialog = document.getElementById("withdrawalDialog");

let currentCashIn = null;
let currentWithdrawal = null;

function peso(value) {
  return `₱${Number(value || 0).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

async function checkAdmin() {
  const user = await requireUser();
  if (!user) return false;

  const { data, error } = await db.rpc("is_current_admin");
  if (error || data !== true) {
    denied.classList.remove("hidden");
    dashboard.classList.add("hidden");
    return false;
  }

  denied.classList.add("hidden");
  dashboard.classList.remove("hidden");
  return true;
}

async function loadCashIns() {
  const selected = document.getElementById("statusFilter").value;
  const [{ data: rows, error }, { data: allRows, error: allError }] = await Promise.all([
    db.rpc("admin_list_cash_ins", { p_status: selected }),
    db.rpc("admin_list_cash_ins", { p_status: "all" })
  ]);

  if (error) return showMessage(adminMessage, error.message);
  if (allError) return showMessage(adminMessage, allError.message);

  const all = allRows || [];
  document.getElementById("adminSummary").innerHTML = `
    <article class="stat-card"><span>Pending cash-ins</span><strong>${all.filter(x => x.status === "pending_review").length}</strong></article>
    <article class="stat-card"><span>Approved cash-ins</span><strong>${all.filter(x => x.status === "approved").length}</strong></article>
    <article class="stat-card"><span>Total approved</span><strong>${peso(all.filter(x => x.status === "approved").reduce((s,x) => s + Number(x.amount), 0))}</strong></article>`;

  document.getElementById("adminCashIns").innerHTML = (rows || []).length
    ? rows.map(row => `
      <tr>
        <td>${new Date(row.reference_submitted_at || row.created_at).toLocaleString()}</td>
        <td><strong>${escapeHtml(row.full_name || "Unnamed user")}</strong><small class="block muted">${escapeHtml(row.email || "")}</small></td>
        <td>${peso(row.amount)}</td>
        <td><code>${escapeHtml(row.reference_number || "Not submitted")}</code></td>
        <td><span class="request-status ${escapeHtml(row.status)}">${escapeHtml(row.status.replaceAll("_"," "))}</span></td>
        <td>${escapeHtml(row.admin_note || "")}</td>
        <td>${row.status === "pending_review" ? `<button class="primary cash-review-btn" data-id="${row.id}" data-amount="${row.amount}" data-reference="${escapeHtml(row.reference_number || "")}" data-user="${escapeHtml(row.full_name || "User")}">Review</button>` : "—"}</td>
      </tr>`).join("")
    : '<tr><td colspan="7">No cash-in requests under this filter.</td></tr>';

  document.querySelectorAll(".cash-review-btn").forEach(button => {
    button.addEventListener("click", () => {
      currentCashIn = { ...button.dataset };
      document.getElementById("dialogTitle").textContent = `Review ${currentCashIn.user}`;
      document.getElementById("dialogDetails").textContent =
        `Amount: ${peso(currentCashIn.amount)} · Reference: ${currentCashIn.reference}`;
      document.getElementById("adminNote").value = "";
      cashDialog.showModal();
    });
  });
}

async function loadWithdrawals() {
  const selected = document.getElementById("withdrawalStatusFilter").value;
  const { data: rows, error } = await db.rpc("admin_list_withdrawals", { p_status: selected });
  if (error) return showMessage(withdrawalAdminMessage, error.message);

  document.getElementById("adminWithdrawals").innerHTML = (rows || []).length
    ? rows.map(row => `
      <tr>
        <td>${new Date(row.created_at).toLocaleString()}</td>
        <td><strong>${escapeHtml(row.full_name || "Unnamed user")}</strong><small class="block muted">${escapeHtml(row.email || "")}</small></td>
        <td>${peso(row.amount)}</td>
        <td><strong>${escapeHtml(row.gcash_name)}</strong><small class="block muted">${escapeHtml(row.gcash_number)}</small></td>
        <td><span class="request-status ${escapeHtml(row.status)}">${escapeHtml(row.status.replaceAll("_"," "))}</span></td>
        <td>${escapeHtml(row.admin_note || "")}</td>
        <td>${row.status === "pending_review" ? `<button class="primary withdrawal-review-btn" data-id="${row.id}" data-amount="${row.amount}" data-name="${escapeHtml(row.gcash_name)}" data-number="${escapeHtml(row.gcash_number)}" data-user="${escapeHtml(row.full_name || "User")}">Review</button>` : "—"}</td>
      </tr>`).join("")
    : '<tr><td colspan="7">No withdrawal requests under this filter.</td></tr>';

  document.querySelectorAll(".withdrawal-review-btn").forEach(button => {
    button.addEventListener("click", () => {
      currentWithdrawal = { ...button.dataset };
      document.getElementById("withdrawalDialogTitle").textContent =
        `Review ${currentWithdrawal.user}`;
      document.getElementById("withdrawalDialogDetails").textContent =
        `${peso(currentWithdrawal.amount)} · ${currentWithdrawal.name} · ${currentWithdrawal.number}`;
      document.getElementById("withdrawalAdminNote").value = "";
      withdrawalDialog.showModal();
    });
  });
}

async function loadAdmin() {
  if (!(await checkAdmin())) return;
  await Promise.all([loadCashIns(), loadWithdrawals()]);
}

cashDialog.addEventListener("close", async () => {
  if (!currentCashIn || !["approve","reject"].includes(cashDialog.returnValue)) return;

  const approve = cashDialog.returnValue === "approve";
  const note = document.getElementById("adminNote").value.trim();
  if (!approve && !note) {
    showMessage(adminMessage, "A rejection reason is required.");
    currentCashIn = null;
    return;
  }

  const { error } = await db.rpc("review_cash_in_request", {
    p_request_id: currentCashIn.id,
    p_approve: approve,
    p_admin_note: note || null
  });
  currentCashIn = null;

  if (error) return showMessage(adminMessage, error.message);
  showMessage(adminMessage, approve ? "Cash-in approved and wallet credited." : "Cash-in rejected.", true);
  await loadCashIns();
});

withdrawalDialog.addEventListener("close", async () => {
  if (!currentWithdrawal || !["approve","reject"].includes(withdrawalDialog.returnValue)) return;

  const approve = withdrawalDialog.returnValue === "approve";
  const note = document.getElementById("withdrawalAdminNote").value.trim();
  if (!approve && !note) {
    showMessage(withdrawalAdminMessage, "A rejection reason is required.");
    currentWithdrawal = null;
    return;
  }

  const { error } = await db.rpc("review_withdrawal_request", {
    p_request_id: currentWithdrawal.id,
    p_approve: approve,
    p_admin_note: note || null
  });
  currentWithdrawal = null;

  if (error) return showMessage(withdrawalAdminMessage, error.message);
  showMessage(withdrawalAdminMessage, approve ? "Withdrawal approved and wallet deducted." : "Withdrawal rejected.", true);
  await loadWithdrawals();
});

document.getElementById("refreshAdmin").addEventListener("click", loadAdmin);
document.getElementById("statusFilter").addEventListener("change", loadCashIns);
document.getElementById("withdrawalStatusFilter").addEventListener("change", loadWithdrawals);

loadAdmin();
