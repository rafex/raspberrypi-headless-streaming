(() => {
  "use strict";

  // El token CSRF vive solo en memoria (no localStorage) para reducir el
  // impacto de un XSS: se pierde al recargar la página, lo cual está bien,
  // ya que la sesión sigue activa por cookie y basta con un GET /api/status
  // exitoso + un nuevo login para refrescar el token si se necesita mutar.
  let csrfToken = null;
  let role = null;
  let pollHandle = null;

  const SERVICE_LABELS = {
    streaming: "Stream (sin overlay)",
    "streaming-overlay": "Stream (con overlay)",
  };

  const $ = (id) => document.getElementById(id);

  async function api(path, { method = "GET", body } = {}) {
    const headers = { "Content-Type": "application/json" };
    if (csrfToken && method !== "GET") headers["X-CSRF-Token"] = csrfToken;

    const res = await fetch(path, {
      method,
      headers,
      credentials: "same-origin",
      body: body ? JSON.stringify(body) : undefined,
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `Error ${res.status}`);
    return data;
  }

  function showDashboard() {
    $("login-view").hidden = true;
    $("dashboard-view").hidden = false;
    $("config-section").hidden = role !== "operator";
  }

  function showLogin() {
    $("dashboard-view").hidden = true;
    $("login-view").hidden = false;
    if (pollHandle) clearInterval(pollHandle);
  }

  function renderServices(statusByService) {
    const container = $("services");
    container.innerHTML = "";

    for (const [service, label] of Object.entries(SERVICE_LABELS)) {
      const info = statusByService[service] || { active: false, state: "desconocido" };
      const card = document.createElement("div");
      card.className = "service-card";
      card.innerHTML = `
        <div class="name">${label}</div>
        <span class="badge ${info.active ? "active" : "inactive"}">
          ${info.active ? "Activo" : "Detenido"} — ${info.state}
        </span>
        ${role === "operator" ? `
          <div class="service-actions">
            <button data-action="start" data-service="${service}" ${info.active ? "disabled" : ""}>Iniciar</button>
            <button data-action="stop" data-service="${service}" class="btn-stop" ${!info.active ? "disabled" : ""}>Detener</button>
          </div>` : ""}
      `;
      container.appendChild(card);
    }

    if (role === "operator") {
      container.querySelectorAll("button[data-action]").forEach((btn) => {
        btn.addEventListener("click", () => handleStreamAction(btn.dataset.service, btn.dataset.action));
      });
    }
  }

  async function handleStreamAction(service, action) {
    try {
      await api(`/api/stream/${service}/${action}`, { method: "POST" });
      await refreshStatus();
    } catch (err) {
      alert(err.message);
    }
  }

  async function refreshStatus() {
    try {
      const data = await api("/api/status");
      renderServices(data);
    } catch (err) {
      // Sesión expirada u otro error de auth: volver al login.
      showLogin();
    }
  }

  async function loadConfig() {
    if (role !== "operator") return;
    try {
      const cfg = await api("/api/config");
      $("cfg-rtmp-url").value = cfg.RTMP_URL || "";
      $("cfg-width").value = cfg.STREAM_WIDTH || "";
      $("cfg-height").value = cfg.STREAM_HEIGHT || "";
      $("cfg-fps").value = cfg.STREAM_FPS || "";
      $("cfg-bitrate").value = cfg.STREAM_BITRATE || "";
      $("cfg-preset").value = cfg.STREAM_PRESET || "veryfast";
    } catch (err) {
      // ignorar, el formulario queda vacío
    }
  }

  $("login-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    $("login-error").hidden = true;

    try {
      const result = await api("/api/login", {
        method: "POST",
        body: { username: $("username").value, password: $("password").value },
      });
      csrfToken = result.csrf_token;
      role = result.role;
      $("session-info").textContent = `${result.user} (${role})`;
      showDashboard();
      await refreshStatus();
      await loadConfig();
      pollHandle = setInterval(refreshStatus, 5000);
    } catch (err) {
      $("login-error").textContent = err.message;
      $("login-error").hidden = false;
    }
  });

  $("logout-btn").addEventListener("click", async () => {
    try {
      await api("/api/logout", { method: "POST" });
    } catch (err) {
      // si ya no había sesión, no importa
    }
    csrfToken = null;
    role = null;
    showLogin();
  });

  $("config-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const msg = $("config-msg");
    msg.hidden = true;

    try {
      await api("/api/config", {
        method: "PUT",
        body: {
          rtmp_url: $("cfg-rtmp-url").value,
          width: Number($("cfg-width").value),
          height: Number($("cfg-height").value),
          fps: Number($("cfg-fps").value),
          bitrate: Number($("cfg-bitrate").value),
          preset: $("cfg-preset").value,
        },
      });
      msg.textContent = "Configuración guardada.";
      msg.className = "";
      msg.hidden = false;
    } catch (err) {
      msg.textContent = err.message;
      msg.className = "error";
      msg.hidden = false;
    }
  });
})();
