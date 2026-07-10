(() => {
  "use strict";

  const DEVICE_ID = "raspi3b";
  const tokenKey = "streaming_api_admin_token";
  const $ = (id) => document.getElementById(id);

  function token() {
    return sessionStorage.getItem(tokenKey) || "";
  }

  async function api(path, { method = "GET", body } = {}) {
    const headers = {
      "Authorization": `Bearer ${token()}`,
      "Content-Type": "application/json",
    };
    const res = await fetch(path, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || data.error || `Error ${res.status}`);
    return data;
  }

  async function headless(path, options = {}) {
    return api(`/ui/api/raspi/${DEVICE_ID}/headless/${path.replace(/^\//, "")}`, options);
  }

  function showMessage(text, isError = false) {
    $("message").hidden = false;
    $("message").className = isError ? "error" : "message";
    $("message").textContent = text;
  }

  async function copyText(text) {
    if (!text || text === "-") return;
    try {
      await navigator.clipboard.writeText(text);
      showMessage("Comando SSH copiado");
    } catch {
      const input = document.createElement("textarea");
      input.value = text;
      input.setAttribute("readonly", "");
      input.style.position = "fixed";
      input.style.opacity = "0";
      document.body.appendChild(input);
      input.select();
      document.execCommand("copy");
      input.remove();
      showMessage("Comando SSH copiado");
    }
  }

  function setDashboardVisible(visible) {
    $("auth-card").hidden = visible;
    $("dashboard").hidden = !visible;
  }

  function serviceBadge(service) {
    const active = Boolean(service?.active);
    return `<span class="badge ${active ? "active" : "inactive"}">${active ? "Activo" : "Detenido"} - ${service?.state || "desconocido"}</span>`;
  }

  function renderServices(services = {}) {
    const pick = (...keys) => keys.map((key) => services[key]).find(Boolean);
    const known = [
      ["streaming", "Streaming"],
      [["streaming-overlay", "streaming_overlay"], "Streaming overlay"],
      ["preview", "Preview"],
      [["web-api", "web_api"], "Portal local"],
      [["ngrok-web", "ngrok_web"], "ngrok"],
      ["backend_agent", "Backend agent"],
    ];
    $("services").innerHTML = known.map(([keys, label]) => `
      <div class="service">
        <div class="name">${label}</div>
        ${serviceBadge(Array.isArray(keys) ? pick(...keys) : services[keys])}
      </div>
    `).join("");
  }

  function renderState(state, config, localStatus) {
    const health = state.last_health || {};
    const services = localStatus || health.services || {};
    const ngrokUrl = health.ngrok_url || "";
    const sshCommand = health.ngrok_ssh_command || "";
    const wifi = health.wifi_ssid || "-";

    $("connection-state").textContent = ngrokUrl ? "Raspi comunicada" : "Sin tunnel reportado";
    $("last-seen").textContent = state.last_seen_at ? new Date(state.last_seen_at).toLocaleString() : "sin reporte";
    $("last-seen").className = `badge ${state.last_seen_at ? "active" : "inactive"}`;
    $("wifi-ssid").textContent = wifi;
    $("ip-address").textContent = health.ip || "-";
    $("default-route").textContent = health.default_route || "-";
    $("ngrok-url").textContent = ngrokUrl || "-";
    $("ngrok-url").href = ngrokUrl || "#";
    $("ssh-command").textContent = sshCommand || "-";
    $("copy-ssh-btn").disabled = !sshCommand;
    renderServices(services);
    $("config-view").textContent = JSON.stringify(config || health.stream_config || {}, null, 2);
  }

  async function refresh() {
    if (!token()) {
      setDashboardVisible(false);
      return;
    }
    $("refresh-btn").disabled = true;
    try {
      setDashboardVisible(true);
      const state = await api(`/ui/api/raspi/${DEVICE_ID}/state`);
      let localStatus = null;
      let config = null;
      try {
        localStatus = await headless("/api/status");
      } catch (err) {
        showMessage(`API headless no disponible: ${err.message}`, true);
      }
      try {
        config = await headless("/api/config");
      } catch {}
      renderState(state, config, localStatus);
    } catch (err) {
      setDashboardVisible(false);
      $("auth-error").textContent = err.message;
      $("auth-error").hidden = false;
    } finally {
      $("refresh-btn").disabled = false;
    }
  }

  async function runCommand(label, path) {
    showMessage(`${label}...`);
    document.querySelectorAll("button").forEach((btn) => { btn.disabled = true; });
    try {
      await headless(path, { method: "POST" });
      showMessage(`${label}: enviado`);
      await refresh();
    } catch (err) {
      showMessage(err.message, true);
    } finally {
      document.querySelectorAll("button").forEach((btn) => { btn.disabled = false; });
    }
  }

  $("save-token-btn").addEventListener("click", async () => {
    const value = $("admin-token").value.trim();
    if (!value) return;
    sessionStorage.setItem(tokenKey, value);
    $("auth-error").hidden = true;
    await refresh();
  });

  $("refresh-btn").addEventListener("click", refresh);
  $("stop-all-btn").addEventListener("click", () => runCommand("Stop all", "/api/stream/stop-all"));
  $("start-stream-btn").addEventListener("click", () => runCommand("Iniciar stream", "/api/stream/streaming/start"));
  $("start-overlay-btn").addEventListener("click", () => runCommand("Iniciar con overlay", "/api/stream/streaming-overlay/start"));
  $("start-preview-btn").addEventListener("click", () => runCommand("Iniciar preview", "/api/stream/preview/start"));
  $("copy-ssh-btn").addEventListener("click", () => copyText($("ssh-command").textContent.trim()));

  const existing = token();
  if (existing) {
    $("admin-token").value = existing;
    refresh();
  }
  setInterval(refresh, 15_000);
})();
