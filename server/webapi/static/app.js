(() => {
  "use strict";

  // El token CSRF vive solo en memoria (no localStorage) para reducir el
  // impacto de un XSS: se pierde al recargar la página, lo cual está bien,
  // ya que la sesión sigue activa por cookie y basta con un GET /api/status
  // exitoso + un nuevo login para refrescar el token si se necesita mutar.
  let csrfToken = null;
  let role = null;
  let eventSource = null;
  let overlayPref = false;

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
    if (eventSource) { eventSource.close(); eventSource = null; }
  }

  function renderServices(statusByService) {
    const plain   = statusByService["streaming"]         || { active: false, state: "desconocido" };
    const overlay = statusByService["streaming-overlay"] || { active: false, state: "desconocido" };

    const isActive     = plain.active || overlay.active;
    const withOverlay  = overlay.active;
    const activeService = plain.active ? "streaming" : overlay.active ? "streaming-overlay" : null;
    const state        = isActive ? (plain.active ? plain.state : overlay.state) : "detenido";

    const showOverlay = isActive ? withOverlay : overlayPref;

    const container = $("services");
    container.innerHTML = `
      <div class="service-card">
        <div class="name">Stream</div>
        <span class="badge ${isActive ? "active" : "inactive"}">
          ${isActive ? "Activo" + (withOverlay ? " — con overlay" : "") : "Detenido"} — ${state}
        </span>
        ${role === "operator" ? `
          <div class="toggle-row overlay-toggle${isActive ? " is-disabled" : ""}">
            <span>Con overlay</span>
            <label class="toggle-switch">
              <input type="checkbox" id="stream-overlay-toggle"
                ${showOverlay ? "checked" : ""} ${isActive ? "disabled" : ""}>
              <span class="toggle-slider"></span>
            </label>
          </div>
          <div class="service-actions">
            <button id="btn-stream-start" class="btn-start" ${isActive ? "disabled" : ""}>Iniciar</button>
            <button id="btn-stream-stop" class="btn-stop" ${!isActive ? "disabled" : ""}>Detener</button>
          </div>` : ""}
      </div>
    `;

    const overlayConfig = $("overlay-config");
    if (overlayConfig) overlayConfig.hidden = !showOverlay;

    if (role === "operator") {
      document.getElementById("stream-overlay-toggle")?.addEventListener("change", (e) => {
        overlayPref = e.target.checked;
        if (overlayConfig) overlayConfig.hidden = !overlayPref;
      });
      document.getElementById("btn-stream-start")?.addEventListener("click", () => {
        handleStreamAction(overlayPref ? "streaming-overlay" : "streaming", "start");
      });
      document.getElementById("btn-stream-stop")?.addEventListener("click", () => {
        handleStreamAction(activeService || "streaming", "stop");
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
      showLogin();
    }
  }

  function startEventSource() {
    if (eventSource) eventSource.close();
    eventSource = new EventSource("/api/events");
    eventSource.onmessage = (e) => {
      try { renderServices(JSON.parse(e.data)); } catch {}
    };
    eventSource.onerror = () => {
      eventSource.close();
      eventSource = null;
      showLogin();
    };
  }

  const RESOLUTION_PRESETS = {
    "480p":  { width: 854,  height: 480,  fps: 30, bitrate: 1500000 },
    "720p":  { width: 1280, height: 720,  fps: 30, bitrate: 2500000 },
    "1080p": { width: 1920, height: 1080, fps: 30, bitrate: 4500000 },
  };

  function setResolution({ width, height, fps, bitrate }) {
    $("cfg-width").value      = width;
    $("cfg-height").value     = height;
    $("cfg-fps").value        = fps;
    $("cfg-bitrate").value    = bitrate;
    $("cfg-width-vis").value  = width;
    $("cfg-height-vis").value = height;
    $("cfg-fps-vis").value    = fps;
    $("cfg-bitrate-vis").value = bitrate;
    document.querySelectorAll(".preset-bar button").forEach((b) =>
      b.classList.toggle("active", b.dataset.preset && RESOLUTION_PRESETS[b.dataset.preset]?.width === width)
    );
  }

  document.querySelectorAll(".preset-bar button[data-preset]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const p = RESOLUTION_PRESETS[btn.dataset.preset];
      if (p) setResolution(p);
    });
  });

  ["cfg-width-vis", "cfg-height-vis", "cfg-fps-vis", "cfg-bitrate-vis"].forEach((id) => {
    $(id)?.addEventListener("input", () => {
      const key = id.replace("-vis", "").replace("cfg-", "cfg-");
      $(key).value = $(id).value;
      document.querySelectorAll(".preset-bar button").forEach((b) => b.classList.remove("active"));
    });
  });

  async function loadConfig() {
    if (role !== "operator") return;
    try {
      const cfg = await api("/api/config");
      $("cfg-rtmp-url").value = cfg.RTMP_URL || "";
      setResolution({
        width:   cfg.STREAM_WIDTH   || 1280,
        height:  cfg.STREAM_HEIGHT  || 720,
        fps:     cfg.STREAM_FPS     || 30,
        bitrate: cfg.STREAM_BITRATE || 2500000,
      });
      $("cfg-preset").value = cfg.STREAM_PRESET || "veryfast";
      $("cfg-overlay-text").value = cfg.OVERLAY_TEXT || "";
      $("cfg-overlay-text-pos").value = cfg.OVERLAY_TEXT_POS || "bl";
      $("cfg-overlay-timestamp").checked = cfg.OVERLAY_TIMESTAMP === "true";
      $("cfg-overlay-logo-file").value = cfg.OVERLAY_LOGO_FILE || "";
      $("cfg-overlay-logo-pos").value = cfg.OVERLAY_LOGO_POS || "br";
      $("cfg-overlay-logo-pad").value = cfg.OVERLAY_LOGO_PAD || "20";
    } catch (err) {
      // ignorar, el formulario queda vacío
    }
  }

  $("logo-file-input").addEventListener("change", async () => {
    const file = $("logo-file-input").files[0];
    if (!file) return;
    const msgEl = $("logo-upload-msg");
    msgEl.textContent = "Subiendo...";
    msgEl.className = "section-label";
    msgEl.hidden = false;

    const formData = new FormData();
    formData.append("file", file);

    try {
      const res = await fetch("/api/logo", {
        method: "POST",
        headers: csrfToken ? { "X-CSRF-Token": csrfToken } : {},
        credentials: "same-origin",
        body: formData,
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `Error ${res.status}`);
      $("cfg-overlay-logo-file").value = data.path;
      msgEl.textContent = `Subido: ${data.filename}`;
      msgEl.className = "section-label";
    } catch (err) {
      msgEl.textContent = err.message;
      msgEl.className = "error";
    }
    $("logo-file-input").value = "";
  });

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
      startEventSource();
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

  function buildConfigBody() {
    return {
      rtmp_url:           $("cfg-rtmp-url").value,
      width:              Number($("cfg-width").value),
      height:             Number($("cfg-height").value),
      fps:                Number($("cfg-fps").value),
      bitrate:            Number($("cfg-bitrate").value),
      preset:             $("cfg-preset").value,
      overlay_text:       $("cfg-overlay-text").value,
      overlay_text_pos:   $("cfg-overlay-text-pos").value,
      overlay_timestamp:  $("cfg-overlay-timestamp").checked,
      overlay_logo_file:  $("cfg-overlay-logo-file").value,
      overlay_logo_pos:   $("cfg-overlay-logo-pos").value,
      overlay_logo_pad:   Number($("cfg-overlay-logo-pad").value) || 20,
    };
  }

  async function saveConfig(msgEl) {
    msgEl.hidden = true;
    try {
      await api("/api/config", { method: "PUT", body: buildConfigBody() });
      msgEl.textContent = "Guardado.";
      msgEl.className = "";
      msgEl.hidden = false;
    } catch (err) {
      msgEl.textContent = err.message;
      msgEl.className = "error";
      msgEl.hidden = false;
    }
  }

  $("config-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    saveConfig($("config-msg"));
  });

  $("save-overlay-btn").addEventListener("click", () => {
    saveConfig($("overlay-msg"));
  });
})();
