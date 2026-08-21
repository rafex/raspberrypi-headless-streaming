(() => {
  "use strict";

  let csrfToken = null;
  let role = null;
  let eventSource = null;
  let gpuEncoderPref = false;
  let lastSavedConfigJSON = null;
  let lastServicesRenderKey = null;
  let savedCustomRtmpUrl = "";
  let loginInFlight = false;

  const $ = (id) => document.getElementById(id);

  const PLATFORM_BASE = {
    youtube:  "rtmp://a.rtmp.youtube.com/live2/",
    facebook: "rtmps://live-api-s.facebook.com:443/rtmp/",
  };
  const PLATFORM_NAMES = {
    youtube: "YouTube", facebook: "Facebook",
    dual: "YouTube + Facebook", custom: "Custom",
  };

  // Micrófonos que usan 48 kHz por defecto (coincide con mic_default_rate en common.sh)
  const MIC_48K_RE = /boya|focusrite|scarlett/i;

  const http = window.createStreamingApiClient({
    getHeaders: (method, formData) => {
      const headers = {};
      if (csrfToken && method !== "GET") headers["X-CSRF-Token"] = csrfToken;
      if (formData) delete headers["Content-Type"];
      return headers;
    },
  });

  async function api(path, options = {}) {
    return http.request(path, options);
  }

  function showDashboard() {
    $("login-view").hidden = true;
    $("dashboard-view").hidden = false;
    $("config-section").hidden = role !== "operator";
  }

  function showLogin() {
    $("dashboard-view").hidden = true;
    $("login-view").hidden = false;
    setLoginLoading(false);
    lastServicesRenderKey = null;
    setActionStatus("");
    if (eventSource) { eventSource.close(); eventSource = null; }
    closeMicStream();
    focusLoginField("username");
  }

  function setLoginLoading(loading) {
    const submit = $("login-submit");
    const status = $("login-status");
    const form = $("login-form");
    const view = $("login-view");
    const label = submit.querySelector(".login-submit-label");
    submit.disabled = loading;
    submit.classList.toggle("is-loading", loading);
    submit.setAttribute("aria-busy", loading ? "true" : "false");
    form.setAttribute("aria-busy", loading ? "true" : "false");
    view.classList.toggle("is-authenticating", loading);
    $("username").disabled = loading;
    $("password").disabled = loading;
    label.textContent = loading ? "Iniciando sesión…" : "Entrar";
    status.textContent = loading ? "Iniciando sesión" : "";
    status.hidden = !loading;
  }

  function focusLoginField(id) {
    if ($("login-view").hidden) return;
    const field = $(id);
    if (!field || field.disabled) return;
    requestAnimationFrame(() => field.focus());
  }

  function setActionStatus(message, tone = "") {
    const status = $("action-status");
    if (!status) return;
    status.textContent = message;
    status.className = `action-status${tone ? ` ${tone}` : ""}`;
    status.hidden = !message;
  }

  // ──────────────────────────────────────────────────
  // Tarjeta de stream
  // ──────────────────────────────────────────────────
  function renderServices(statusByService) {
    const plain   = statusByService["streaming"]         || { active: false, state: "desconocido" };
    const overlay = statusByService["streaming-overlay"] || { active: false, state: "desconocido" };
    const isActive      = plain.active || overlay.active;
    const withOverlay   = overlay.active;
    const activeService = plain.active ? "streaming" : overlay.active ? "streaming-overlay" : null;
    const state         = isActive ? (plain.active ? plain.state : overlay.state) : "detenido";
    const renderKey = JSON.stringify({
      role,
      streaming: [plain.active, plain.state],
      overlay: [overlay.active, overlay.state],
    });
    if (renderKey === lastServicesRenderKey) return;
    lastServicesRenderKey = renderKey;

    const actions = $("global-actions");
    actions.replaceChildren();
    if (role === "operator") {
      const stopAll = document.createElement("button");
      stopAll.id = "btn-global-stop-all";
      stopAll.className = "btn-stop-all global-stop";
      stopAll.textContent = "Stop all";
      stopAll.addEventListener("click", (e) => handleStopAll(e.currentTarget));
      actions.appendChild(stopAll);
    }

    const servicesEl = $("services");
    servicesEl.replaceChildren();
    const card = document.createElement("div");
    card.className = "service-card";
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = "Stream";
    const badge = document.createElement("span");
    badge.className = `badge ${isActive ? "active" : "inactive"}`;
    badge.textContent = `${isActive ? "Activo" + (withOverlay ? " — con overlay" : "") : "Detenido"} — ${String(state)}`;
    card.append(name, badge);
    if (role === "operator") {
      const serviceActions = document.createElement("div");
      serviceActions.className = "service-actions";
      const start = document.createElement("button");
      start.id = "btn-stream-start";
      start.className = "btn-start";
      start.textContent = "Iniciar";
      start.disabled = isActive;
      const stop = document.createElement("button");
      stop.id = "btn-stream-stop";
      stop.className = "btn-stop";
      stop.textContent = "Detener";
      stop.disabled = !isActive;
      serviceActions.append(start, stop);
      card.appendChild(serviceActions);
      start.addEventListener("click", (e) => {
        if (!confirmStartWithUnsavedChanges()) return;
        handleStreamAction((anyOverlayActive() || gpuEncoderPref) ? "streaming-overlay" : "streaming", "start", e.currentTarget);
      });
      stop.addEventListener("click", (e) => handleStreamAction(activeService || "streaming", "stop", e.currentTarget));
    }
    servicesEl.appendChild(card);

    if (role === "operator") {
      // streaming-overlay.service handles overlays and GPU encoding.
    }
  }

  // Deshabilita el botón clickeado de inmediato (antes de esperar la red) para
  // que un doble-click no dispare dos requests concurrentes — start/stop ya
  // son idempotentes en el backend, pero esto evita el parpadeo de la UI y
  // gastar sudo de más mientras se espera la respuesta.
  async function handleStreamAction(service, action, btn) {
    if (btn) btn.disabled = true;
    if (btn) btn.setAttribute("aria-busy", "true");
    setActionStatus(action === "start" ? "Iniciando transmisión..." : "Deteniendo transmisión...");
    try {
      await api(`/api/stream/${service}/${action}`, { method: "POST" });
      setActionStatus("Operación completada.", "success");
    } catch (err) {
      setActionStatus(err.message, "error");
    } finally {
      await refreshStatus();
      if (btn) btn.setAttribute("aria-busy", "false");
    }
  }

  async function handleStopAll(btn) {
    if (!confirm("¿Detener todas las transmisiones, previews y servicios relacionados?")) return;
    if (btn) btn.disabled = true;
    if (btn) btn.setAttribute("aria-busy", "true");
    setActionStatus("Deteniendo todos los servicios...");
    try {
      await api("/api/stream/stop-all", { method: "POST" });
      setActionStatus("Todos los servicios fueron detenidos.", "success");
    } catch (err) {
      setActionStatus(err.message, "error");
    } finally {
      await refreshStatus();
      if (btn) btn.setAttribute("aria-busy", "false");
    }
  }

  function anyServiceActive(data) {
    return Boolean(data?.["streaming"]?.active || data?.["streaming-overlay"]?.active || data?.["preview"]?.active);
  }

  async function refreshStatus() {
    try {
      const data = await api("/api/status");
      renderServices(data);
      updatePreviewStatus(data["preview"]);
      lockOverlayToggle(anyServiceActive(data));
    } catch (err) {
      if (err.status === 401) {
        csrfToken = null;
        role = null;
        showLogin();
        return;
      }
      setActionStatus("No se pudo actualizar el estado. Reintentando...", "error");
    }
  }

  function startEventSource() {
    if (eventSource) eventSource.close();
    eventSource = new EventSource("/api/events");
    eventSource.onmessage = (e) => {
      try {
        const payload = JSON.parse(e.data);
        const data = payload.services || payload;
        renderServices(data);
        updatePreviewStatus(data["preview"]);
        lockOverlayToggle(anyServiceActive(data));
      } catch {}
    };
    eventSource.onerror = () => {
      eventSource.close(); eventSource = null;
      setActionStatus("Conexión en recuperación; el estado puede estar desactualizado...", "error");
      // Verificar si la sesión sigue activa o si es un error transitorio (429, red, etc.)
      fetch("/api/status", { credentials: "same-origin" }).then((r) => {
        if (r.status === 401) {
          csrfToken = null;
          role = null;
          showLogin();
          return;
        }
        // Sesión OK — reintentar SSE en 30s (puede ser 429 u otro error transitorio)
        setTimeout(startEventSource, 30_000);
      }).catch(() => setTimeout(startEventSource, 30_000));
    };
  }

  // ──────────────────────────────────────────────────
  // Vista previa local (RTMP vía mediamtx, o MPEG-TS por TCP/UDP)
  // Reutiliza cámara/audio/overlays ya configurados — nunca toca el
  // destino real (YouTube/Facebook/custom), eso lo garantiza el backend.
  // ──────────────────────────────────────────────────
  let previewShellBuilt = false;

  function buildPreviewShell() {
    if (role !== "operator") {
      $("preview-card").innerHTML = "";
      previewShellBuilt = false;
      return;
    }
    if (previewShellBuilt) return;

    $("preview-card").innerHTML = `
      <div class="service-card">
        <div class="name">Vista previa</div>
        <span class="badge inactive" id="preview-badge">Detenido</span>
        <p class="field-hint">Prueba cámara/audio/overlays antes de salir en vivo. Nunca transmite a la plataforma real.</p>
        <div class="grid2" style="margin-top:10px">
          <label>Transporte
            <select id="preview-transport">
              <option value="rtmp">RTMP (mediamtx)</option>
              <option value="tcp">TCP (MPEG-TS)</option>
              <option value="udp">UDP (MPEG-TS)</option>
            </select>
          </label>
          <label>Puerto
            <input type="number" id="preview-port" min="1" max="65535" value="1935">
          </label>
        </div>
        <label id="preview-rtmpname-row">
          Nombre del stream (RTMP)
          <input type="text" id="preview-rtmp-name" value="preview">
        </label>
        <label id="preview-clientip-row" hidden>
          IP del cliente (UDP)
          <input type="text" id="preview-client-ip" placeholder="192.168.1.50">
        </label>
        <p class="field-hint">Los overlays activos del paso 6 (Overlays) y el Encoder GPU del paso 5, si están disponibles, también se usan aquí.</p>
        <p class="field-hint" id="preview-url-label"></p>
        <div class="preview-url-row">
          <code id="preview-url-text"></code>
          <button type="button" id="preview-url-copy" class="copy-btn" aria-label="Copiar URL" title="Copiar URL">&#128203;</button>
        </div>
        <div class="service-actions">
          <button id="btn-preview-start" class="btn-start">Iniciar preview</button>
          <button id="btn-preview-stop"  class="btn-stop" disabled>Detener</button>
        </div>
      </div>`;
    previewShellBuilt = true;

    $("preview-transport").addEventListener("change", () => {
      const t = $("preview-transport").value;
      const curPort = Number($("preview-port").value);
      if (t === "rtmp" && curPort === 1234) $("preview-port").value = 1935;
      if (t !== "rtmp" && curPort === 1935) $("preview-port").value = 1234;
      updatePreviewTransportUI();
    });
    ["preview-port", "preview-rtmp-name", "preview-client-ip"].forEach((id) => {
      $(id).addEventListener("input", updatePreviewVlcHint);
    });
    $("btn-preview-start").addEventListener("click", (e) => {
      if (!confirmStartWithUnsavedChanges()) return;
      handlePreviewStart(e.currentTarget);
    });
    $("btn-preview-stop").addEventListener("click", (e) => handleStreamAction("preview", "stop", e.currentTarget));
    $("preview-url-copy").addEventListener("click", (e) => copyPreviewUrl(e.currentTarget));
  }

  function updatePreviewTransportUI() {
    const t = $("preview-transport").value;
    $("preview-rtmpname-row").hidden = t !== "rtmp";
    $("preview-clientip-row").hidden = t !== "udp";
    updatePreviewVlcHint();
  }

  function updatePreviewVlcHint() {
    const t    = $("preview-transport")?.value;
    if (!t) return;
    const port = $("preview-port").value || (t === "rtmp" ? 1935 : 1234);
    const name = $("preview-rtmp-name").value.trim() || "preview";
    const host = window.location.hostname;
    let label = "", url = "";
    if (t === "rtmp") {
      label = "Ver con VLC:";
      url = `rtmp://${host}:1935/${name}`;
    } else if (t === "tcp") {
      label = "Ver con VLC (después de iniciar):";
      url = `tcp://${host}:${port}`;
    } else {
      label = "Ver con VLC en el cliente:";
      url = `udp://@:${port}`;
    }
    $("preview-url-label").textContent = label;
    $("preview-url-text").textContent = url;
  }

  async function copyPreviewUrl(btn) {
    const url = $("preview-url-text")?.textContent || "";
    if (!url) return;
    try {
      await navigator.clipboard.writeText(url);
    } catch {
      // Fallback para contextos sin permiso/API de clipboard (http, navegadores viejos).
      const ta = document.createElement("textarea");
      ta.value = url;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch {}
      document.body.removeChild(ta);
    }
    if (!btn) return;
    const original = btn.textContent;
    btn.textContent = "✓";
    btn.disabled = true;
    setTimeout(() => { btn.textContent = original; btn.disabled = false; }, 1200);
  }

  async function loadPreviewConfig() {
    if (role !== "operator") return;
    try {
      const cfg = await api("/api/preview/config");
      $("preview-transport").value = cfg.PREVIEW_TRANSPORT || "rtmp";
      $("preview-port").value      = cfg.PREVIEW_PORT      || "1935";
      $("preview-rtmp-name").value = cfg.PREVIEW_RTMP_NAME || "preview";
      $("preview-client-ip").value = cfg.PREVIEW_CLIENT_IP || "";
      updatePreviewTransportUI();
    } catch {
      // formulario queda con los valores por default si falla
    }
  }

  function updatePreviewStatus(st) {
    if (role !== "operator" || !previewShellBuilt) return;
    const active = st?.active || false;
    const badge  = $("preview-badge");
    badge.className   = `badge ${active ? "active" : "inactive"}`;
    badge.textContent = `${active ? "Activo" : "Detenido"} — ${st?.state || "desconocido"}`;
    $("btn-preview-start").disabled = active;
    $("btn-preview-stop").disabled  = !active;
    ["preview-transport", "preview-port", "preview-rtmp-name", "preview-client-ip"].forEach((id) => {
      $(id).disabled = active;
    });
  }

  async function handlePreviewStart(btn) {
    if (btn) btn.disabled = true;
    if (btn) btn.setAttribute("aria-busy", "true");
    setActionStatus("Iniciando vista previa...");
    try {
      const transport = $("preview-transport").value;
      await api("/api/preview/config", {
        method: "PUT",
        body: {
          transport,
          port:      Number($("preview-port").value) || (transport === "rtmp" ? 1935 : 1234),
          client_ip: $("preview-client-ip").value.trim(),
          rtmp_name: $("preview-rtmp-name").value.trim() || "preview",
          overlay:   anyOverlayActive(),
        },
      });
      await api("/api/stream/preview/start", { method: "POST" });
      setActionStatus("Vista previa iniciada.", "success");
    } catch (err) {
      setActionStatus(err.message, "error");
    } finally {
      await refreshStatus();
      if (btn) btn.setAttribute("aria-busy", "false");
    }
  }

  // ──────────────────────────────────────────────────
  // Resolución
  // ──────────────────────────────────────────────────
  const RESOLUTION_PRESETS = {
    "360p":  { width: 640,  height: 360,  fps: 30, bitrate: 800000 },
    "480p":  { width: 854,  height: 480,  fps: 30, bitrate: 1500000 },
    "720p":  { width: 1280, height: 720,  fps: 30, bitrate: 2500000 },
    "1080p": { width: 1920, height: 1080, fps: 30, bitrate: 4500000 },
  };

  function setResolution({ width, height, fps, bitrate }) {
    $("cfg-width").value      = width;
    $("cfg-height").value     = height;
    $("cfg-fps").value        = fps;
    $("cfg-width-vis").value  = width;
    $("cfg-height-vis").value = height;
    $("cfg-fps-vis").value    = fps;
    if (bitrate) setBitrate(bitrate);

    document.querySelectorAll(".res-btn").forEach((b) =>
      b.classList.toggle("active", b.dataset.preset && RESOLUTION_PRESETS[b.dataset.preset]?.width === width)
    );
    updateSummaries();
  }

  document.querySelectorAll(".res-btn[data-preset]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const p = RESOLUTION_PRESETS[btn.dataset.preset];
      if (p) setResolution(p);
    });
  });

  ["cfg-width-vis", "cfg-height-vis", "cfg-fps-vis"].forEach((id) => {
    $(id)?.addEventListener("input", () => {
      $(id.replace("-vis", "")).value = $(id).value;
      document.querySelectorAll(".res-btn").forEach((b) => b.classList.remove("active"));
      updateSummaries();
    });
  });

  // ──────────────────────────────────────────────────
  // Bitrate / calidad de video
  // ──────────────────────────────────────────────────
  function setBitrate(bitrate) {
    $("cfg-bitrate").value     = bitrate;
    $("cfg-bitrate-vis").value = bitrate;
    document.querySelectorAll(".quality-card").forEach((b) =>
      b.classList.toggle("active", Number(b.dataset.bitrate) === bitrate)
    );
  }

  document.querySelectorAll(".quality-card[data-bitrate]").forEach((btn) => {
    btn.addEventListener("click", () => {
      setBitrate(Number(btn.dataset.bitrate));
      updateSummaries();
    });
  });

  $("cfg-bitrate-vis")?.addEventListener("input", () => {
    $("cfg-bitrate").value = $("cfg-bitrate-vis").value;
    document.querySelectorAll(".quality-card").forEach((b) => b.classList.remove("active"));
    updateSummaries();
  });

  // ──────────────────────────────────────────────────
  // Platform picker
  // ──────────────────────────────────────────────────
  function updatePlatformUI(platform) {
    const isDual   = platform === "dual";
    const isCustom = platform === "custom";
    $("cfg-stream-key-row").hidden      = isCustom;
    $("cfg-stream-key-meta-row").hidden = !isDual;
    $("cfg-rtmp-url-row").hidden        = !isCustom;
    const label = $("cfg-stream-key-label");
    if (label) label.childNodes[0].textContent = isDual ? "Stream Key YouTube " : "Stream Key ";
  }

  function detectPlatform(rtmpUrl) {
    if (!rtmpUrl) return { platform: "youtube", key: "" };
    if (rtmpUrl.includes("youtube.com"))  return { platform: "youtube",  key: rtmpUrl.split("/").pop() };
    if (rtmpUrl.includes("facebook.com")) return { platform: "facebook", key: rtmpUrl.split("/").pop() };
    return { platform: "custom", key: "" };
  }

  $("cfg-platform").addEventListener("change", () => {
    updatePlatformUI($("cfg-platform").value);
    updateSummaries();
  });

  // ──────────────────────────────────────────────────
  // Audio — auto-hint de sample rate por nombre de mic
  // ──────────────────────────────────────────────────
  function updateAudioDeviceDetails() {
    const opt = $("cfg-audio-device").options[$("cfg-audio-device").selectedIndex];
    const detail = $("audio-device-detail");
    if (!detail || !opt) return;
    if ($("cfg-audio-device").value === "__none__") {
      detail.textContent = "Se enviará silencio AAC para mantener compatibilidad con la plataforma.";
      detail.hidden = false;
      return;
    }
    const description = opt.dataset.description || "";
    const numeric = opt.dataset.numericDev ? ` · alternativo ${opt.dataset.numericDev}` : "";
    detail.textContent = description ? `${description}${numeric}` : "";
    detail.hidden = !description;
  }

  $("cfg-audio-device").addEventListener("change", () => {
    const opt  = $("cfg-audio-device").options[$("cfg-audio-device").selectedIndex];
    const name = opt?.text || "";
    const hint = $("audio-rate-hint");
    const preferredRate = opt?.dataset?.preferredRate;
    if (preferredRate) {
      $("cfg-audio-rate").value = preferredRate;
      hint.textContent = `Sugerido ${Number(preferredRate).toLocaleString("es-MX")} Hz para este micrófono`;
      hint.hidden = false;
    } else if (MIC_48K_RE.test(name)) {
      $("cfg-audio-rate").value = "48000";
      hint.textContent = "Sugerido 48 000 Hz para este micrófono";
      hint.hidden = false;
    } else {
      hint.hidden = true;
    }
    updateAudioDeviceDetails();
    updateSummaries();
  });

  // ──────────────────────────────────────────────────
  // Logo width — chip row
  // ──────────────────────────────────────────────────
  document.querySelectorAll("#logo-w-chips .chip-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const val = Number(btn.dataset.logow);
      $("cfg-overlay-logo-w").value = val;
      document.querySelectorAll("#logo-w-chips .chip-btn").forEach((b) =>
        b.classList.toggle("active", b === btn)
      );
      updateSummaries();
    });
  });

  $("cfg-overlay-logo-w")?.addEventListener("input", () => {
    document.querySelectorAll("#logo-w-chips .chip-btn").forEach((b) => {
      b.classList.toggle("active", Number(b.dataset.logow) === Number($("cfg-overlay-logo-w").value));
    });
    updateSummaries();
  });

  // ──────────────────────────────────────────────────
  // Logo padding — chip row
  // ──────────────────────────────────────────────────
  document.querySelectorAll("#logo-pad-chips .chip-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      $("cfg-overlay-logo-pad").value = Number(btn.dataset.logopad);
      document.querySelectorAll("#logo-pad-chips .chip-btn").forEach((b) =>
        b.classList.toggle("active", b === btn)
      );
    });
  });

  $("cfg-overlay-logo-pad")?.addEventListener("input", () => {
    document.querySelectorAll("#logo-pad-chips .chip-btn").forEach((b) => {
      b.classList.toggle("active", Number(b.dataset.logopad) === Number($("cfg-overlay-logo-pad").value));
    });
  });

  // ──────────────────────────────────────────────────
  // Logo position — 2×2 grid
  // ──────────────────────────────────────────────────
  function setLogoPos(pos) {
    $("cfg-overlay-logo-pos").value = pos;
    document.querySelectorAll(".pos-btn[data-logopos]").forEach((b) => {
      const active = b.dataset.logopos === pos;
      b.classList.toggle("active", active);
      b.setAttribute("aria-pressed", String(active));
    });
  }

  document.querySelectorAll(".pos-btn[data-logopos]").forEach((btn) => {
    btn.addEventListener("click", () => setLogoPos(btn.dataset.logopos));
  });

  // ──────────────────────────────────────────────────
  // Text position — 3×3 grid
  // ──────────────────────────────────────────────────
  function setTextPos(pos) {
    $("cfg-overlay-text-pos").value = pos;
    document.querySelectorAll(".pos-btn[data-textpos]").forEach((b) => {
      const active = b.dataset.textpos === pos;
      b.classList.toggle("active", active);
      b.setAttribute("aria-pressed", String(active));
    });
  }

  document.querySelectorAll(".pos-btn[data-textpos]").forEach((btn) => {
    btn.addEventListener("click", () => setTextPos(btn.dataset.textpos));
  });

  // ──────────────────────────────────────────────────
  // Timestamp position — 3×3 grid
  // ──────────────────────────────────────────────────
  function setTimestampPos(pos) {
    $("cfg-overlay-timestamp-pos").value = pos;
    document.querySelectorAll(".pos-btn[data-timestamppos]").forEach((b) => {
      const active = b.dataset.timestamppos === pos;
      b.classList.toggle("active", active);
      b.setAttribute("aria-pressed", String(active));
    });
  }

  document.querySelectorAll(".pos-btn[data-timestamppos]").forEach((btn) => {
    btn.addEventListener("click", () => setTimestampPos(btn.dataset.timestamppos));
  });

  // ──────────────────────────────────────────────────
  // Banner position — footer / header buttons
  // ──────────────────────────────────────────────────
  function setBannerPos(pos) {
    $("cfg-overlay-banner-pos").value = pos;
    document.querySelectorAll(".banner-pos-btn").forEach((b) => {
      const active = b.dataset.bannerpos === pos;
      b.classList.toggle("active", active);
      b.setAttribute("aria-pressed", String(active));
    });
  }

  document.querySelectorAll(".banner-pos-btn").forEach((btn) => {
    btn.addEventListener("click", () => setBannerPos(btn.dataset.bannerpos));
  });

  // ──────────────────────────────────────────────────
  // Accordion summaries
  // ──────────────────────────────────────────────────
  function updateSummaries() {
    // Cámara
    const h  = $("cfg-height").value || 720;
    const vd = $("cfg-video-device");
    const vdText = vd.selectedIndex > 0
      ? (vd.options[vd.selectedIndex].text.split("(")[0].trim() || "Detectado")
      : "Auto";
    $("sum-camera").textContent = `${vdText} · ${h}p`;

    // Audio
    const ad      = $("cfg-audio-device");
    const noAudio = ad.value === "__none__";
    if (noAudio) {
      $("sum-audio").textContent = "Sin audio (AAC silencio)";
    } else {
      const adText = ad.selectedIndex > 0
        ? (ad.options[ad.selectedIndex].text.split("(")[0].trim() || "Detectado")
        : "Auto";
      const ch   = $("cfg-audio-stereo").checked ? "Stereo" : "Mono";
      const rate = $("cfg-audio-rate").value || "44100";
      const boost = $("cfg-audio-boost").checked ? " ×2" : "";
      $("sum-audio").textContent = `${adText} · ${ch} · ${rate} Hz${boost}`;
    }

    // Destino
    $("sum-dest").textContent = PLATFORM_NAMES[$("cfg-platform").value] || $("cfg-platform").value;

    // Video
    const bitrate = Number($("cfg-bitrate").value || 2500000);
    const preset  = $("cfg-preset").value || "veryfast";
    $("sum-video").textContent = `${Math.round(bitrate / 1000)} kbps · ${preset}`;

    // Encoder
    const sumEncoder = $("sum-encoder");
    if (sumEncoder) sumEncoder.textContent = gpuEncoderPref ? "GPU · h264_v4l2m2m" : "CPU · libx264";

    // Overlays — solo cuenta lo que está habilitado y tiene contenido
    const parts = [
      $("cfg-overlay-logo-enabled").checked   && $("cfg-overlay-logo-file").value.trim() && "Logo",
      $("cfg-overlay-banner-enabled").checked && $("cfg-overlay-banner").value.trim()    && "Banner",
      $("cfg-overlay-text-enabled").checked   && $("cfg-overlay-text").value.trim()      && "Texto",
      $("cfg-overlay-timestamp").checked      && "Hora",
    ].filter(Boolean);
    $("sum-overlay").textContent = parts.length ? parts.join(" · ") : "Ninguno";
  }

  ["cfg-audio-rate", "cfg-preset"].forEach((id) => {
    $(id)?.addEventListener("change", updateSummaries);
  });
  ["cfg-audio-stereo", "cfg-audio-boost", "cfg-overlay-timestamp",
   "cfg-overlay-logo-enabled", "cfg-overlay-banner-enabled", "cfg-overlay-text-enabled"].forEach((id) => {
    $(id)?.addEventListener("change", updateSummaries);
  });
  ["cfg-overlay-logo-file", "cfg-overlay-banner", "cfg-overlay-text"].forEach((id) => {
    $(id)?.addEventListener("input", updateSummaries);
  });

  // Toggle GPU Encoder (h264_v4l2m2m, VideoCore). h264_v4l2m2m acepta frames ya
  // filtrados, así que overlay + GPU encoder pueden usarse juntos sin exclusión mutua.
  $("gpu-encoder-toggle")?.addEventListener("change", (e) => {
    gpuEncoderPref = e.target.checked;
    updateSummaries();
  });

  // Cada toggle de overlay (logo/banner/texto/timestamp) se bloquea mientras
  // hay un servicio activo — igual que el GPU encoder, no cambia sin reiniciar.
  function lockOverlayToggle(anyActive) {
    ["cfg-overlay-logo-enabled", "cfg-overlay-banner-enabled", "cfg-overlay-text-enabled", "cfg-overlay-timestamp"].forEach((id) => {
      const el = $(id);
      if (el) el.disabled = anyActive;
    });
    const gpuToggle = $("gpu-encoder-toggle");
    if (gpuToggle) gpuToggle.disabled = anyActive;
  }

  // ──────────────────────────────────────────────────
  // VU meter + ganancia del micrófono
  // ──────────────────────────────────────────────────
  let micGainInFlight = false;

  function setVu(pct, peakPct) {
    const fill = $("vu-fill");
    const peak = $("vu-peak");
    if (fill) fill.style.width = `${Math.max(0, Math.min(100, pct || 0))}%`;
    if (peak) {
      if (peakPct == null) {
        peak.hidden = true;
      } else {
        peak.hidden = false;
        peak.style.left = `${Math.max(0, Math.min(100, peakPct))}%`;
      }
    }
  }

  function renderMicGain(gain) {
    const slider = $("mic-gain");
    const valEl  = $("mic-gain-val");
    if (!slider) return;
    if (gain && typeof gain.percent === "number") {
      if (!micGainInFlight) slider.value = String(gain.percent);
      slider.disabled = false;
      valEl.textContent = `${gain.percent}%` + (gain.db != null ? ` (${gain.db} dB)` : "");
    } else {
      slider.disabled = true;
      valEl.textContent = "no disponible";
    }
  }

  function renderMicStatus(data) {
    const box = $("mic-meter");
    const msg = $("mic-status");
    if (!box || !msg) return;
    renderMicGain(data.gain);

    box.classList.toggle("is-busy", data.reason === "busy");
    if (data.available && data.level) {
      setVu(data.level.mean_pct, data.level.peak_pct);
      const mean = data.level.mean_db != null ? `${data.level.mean_db} dB` : "—";
      const peak = data.level.max_db != null ? `${data.level.max_db} dB` : "—";
      msg.className = "device-status";
      msg.textContent = `Nivel medio ${mean} · pico ${peak}`;
    } else {
      setVu(0, null);
      msg.className = "device-status";
      if (data.reason === "busy")      msg.textContent = "Transmisión/preview activo: la medición se pausa, pero puedes ajustar la ganancia.";
      else if (data.reason === "no-audio")  msg.textContent = "Sin micrófono configurado (modo sin audio).";
      else if (data.reason === "no-signal") msg.textContent = "No se detectó señal. Verifica el micrófono.";
      else msg.textContent = "Esperando medición…";
    }
  }

  async function refreshMic() {
    if (role !== "operator") return;
    const msg = $("mic-status");
    const btn = $("mic-refresh");
    if (btn) btn.disabled = true;
    if (msg) { msg.className = "device-status"; msg.textContent = "Midiendo…"; }
    try {
      const data = await api("/api/mic/status");
      renderMicStatus(data);
    } catch (err) {
      if (msg) { msg.className = "error"; msg.textContent = err.message; }
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  $("mic-refresh")?.addEventListener("click", refreshMic);

  // SSE del nivel del micrófono: se abre SOLO mientras el acordeón de Audio
  // está desplegado, y se cierra al plegarlo. Así no se mide el device (arecord)
  // cuando nadie está viendo el panel de audio.
  let micEventSource = null;

  function openMicStream() {
    if (role !== "operator" || micEventSource) return;
    const msg = $("mic-status");
    if (msg) { msg.className = "device-status"; msg.textContent = "Midiendo…"; }
    micEventSource = new EventSource("/api/mic/events");
    micEventSource.onmessage = (e) => {
      try { renderMicStatus(JSON.parse(e.data)); } catch {}
    };
    micEventSource.onerror = () => {
      // Cierra en error transitorio; se reabrirá si el acordeón sigue abierto.
      closeMicStream();
      if (isAudioAccordionOpen()) setTimeout(syncMicStream, 30_000);
    };
  }

  function closeMicStream() {
    if (micEventSource) { micEventSource.close(); micEventSource = null; }
  }

  function isAudioAccordionOpen() {
    return Boolean($("acrd-audio")?.open);
  }

  function syncMicStream() {
    if (role === "operator" && isAudioAccordionOpen()) openMicStream();
    else closeMicStream();
  }

  $("acrd-audio")?.addEventListener("toggle", syncMicStream);

  $("mic-gain")?.addEventListener("input", () => {
    const val = $("mic-gain").value;
    $("mic-gain-val").textContent = `${val}%`;
  });

  $("mic-gain")?.addEventListener("change", async () => {
    const percent = Number($("mic-gain").value);
    micGainInFlight = true;
    $("mic-gain").disabled = true;
    try {
      const data = await api("/api/mic/gain", { method: "PUT", body: { percent } });
      renderMicGain(data.gain);
    } catch (err) {
      const msg = $("mic-status");
      if (msg) { msg.className = "error"; msg.textContent = err.message; }
    } finally {
      micGainInFlight = false;
      $("mic-gain").disabled = false;
    }
  });

  // ──────────────────────────────────────────────────
  // Detección de dispositivos
  // ──────────────────────────────────────────────────
  function audioOptionLabel(item) {
    if (!item.description) return `${item.name}  (${item.dev})`;
    return `${item.description}: ${item.name}  (${item.dev})`;
  }

  function populateDeviceSelect(selectEl, items, currentValue) {
    const fixed = Array.from(selectEl.options).filter((o) => o.dataset.fixed === "1");
    selectEl.innerHTML = "";
    fixed.forEach((o) => selectEl.appendChild(o));
    items.forEach((item) => {
      const opt = document.createElement("option");
      opt.value = item.dev;
      opt.textContent = selectEl.id === "cfg-audio-device" ? audioOptionLabel(item) : `${item.name}  (${item.dev})`;
      if (item.description) opt.dataset.description = item.description;
      if (item.preferred_rate) opt.dataset.preferredRate = String(item.preferred_rate);
      if (item.numeric_dev) opt.dataset.numericDev = item.numeric_dev;
      selectEl.appendChild(opt);
    });
    selectEl.value = currentValue || "";
    if (selectEl.value !== (currentValue || "")) {
      const byNumeric = Array.from(selectEl.options).find((opt) => opt.dataset.numericDev === currentValue);
      selectEl.value = byNumeric ? byNumeric.value : "";
    }
  }

  let deviceScanInFlight = false;

  async function loadDevices(currentVideo, currentAudio) {
    if (deviceScanInFlight) return;
    deviceScanInFlight = true;
    const statusEl = $("device-status");
    const scanButton = $("btn-scan-devices");
    if (scanButton) {
      scanButton.disabled = true;
      scanButton.setAttribute("aria-busy", "true");
    }
    statusEl.textContent = "Escaneando...";
    try {
      const { cameras, mics, media } = await api("/api/devices");
      populateDeviceSelect($("cfg-video-device"), cameras, currentVideo);
      populateDeviceSelect($("cfg-audio-device"), mics,    currentAudio);
      const detected = media?.video;
      const audio = media?.audio;
      const mediaText = detected?.device
        ? ` · ${detected.name} ${detected.format} ${detected.width}x${detected.height}@${detected.fps} · audio: ${audio?.name || "silencio AAC"}`
        : "";
      statusEl.textContent =
        `${cameras.length} cámara(s) · ${mics.length} micrófono(s)` +
        (cameras.length === 0 ? " — no se detectaron cámaras" : "") + mediaText;
      updateAudioDeviceDetails();
      updateSummaries();
    } catch (err) {
      statusEl.textContent = `Error al escanear: ${err.message}`;
    } finally {
      deviceScanInFlight = false;
      if (scanButton) {
        scanButton.disabled = false;
        scanButton.setAttribute("aria-busy", "false");
      }
    }
  }

  let audioScanInFlight = false;

  async function scanAudioDevices() {
    if (audioScanInFlight) return;
    audioScanInFlight = true;
    const statusEl = $("audio-scan-status");
    const audioSelect = $("cfg-audio-device");
    const scanButton = $("btn-scan-audio");
    if (scanButton) {
      scanButton.disabled = true;
      scanButton.setAttribute("aria-busy", "true");
    }
    const currentAudio = audioSelect.value;
    statusEl.textContent = "Escaneando audio...";
    try {
      const { mics = [], media } = await api("/api/devices");
      populateDeviceSelect(audioSelect, mics, currentAudio);
      const detected = media?.audio;
      statusEl.textContent = `${mics.length} micrófono(s)` +
        (detected?.device
          ? ` · detectado: ${detected.name || detected.device}`
          : " · sin entrada detectada");
      updateAudioDeviceDetails();
      updateSummaries();
    } catch (err) {
      statusEl.textContent = `Error al escanear audio: ${err.message}`;
    } finally {
      audioScanInFlight = false;
      if (scanButton) {
        scanButton.disabled = false;
        scanButton.setAttribute("aria-busy", "false");
      }
    }
  }

  $("btn-scan-devices").addEventListener("click", () => loadDevices("", ""));
  $("btn-scan-audio").addEventListener("click", scanAudioDevices);

  // ──────────────────────────────────────────────────
  // Cargar configuración guardada
  // ──────────────────────────────────────────────────
  async function loadConfig() {
    if (role !== "operator") return;
    try {
      const cfg = await api("/api/config");

      setResolution({
        width:   Number(cfg.STREAM_WIDTH)   || 1280,
        height:  Number(cfg.STREAM_HEIGHT)  || 720,
        fps:     Number(cfg.STREAM_FPS)     || 30,
        bitrate: Number(cfg.STREAM_BITRATE) || 2500000,
      });
      $("cfg-preset").value = cfg.STREAM_PRESET || "veryfast";

      // Plataforma
      let platform     = cfg.STREAM_PLATFORM || "";
      const streamKeyConfigured = Boolean(cfg.STREAM_KEY);
      const streamKeyMetaConfigured = Boolean(cfg.STREAM_KEY_META);
      let streamKey    = "";
      let streamKeyMeta = "";
      if (!platform) {
        const det = detectPlatform(cfg.RTMP_URL || "");
        platform  = det.platform;
        streamKey = det.key;
      }
      if (cfg.STREAM_DUAL === "true") platform = "dual";
      $("cfg-platform").value        = platform || "youtube";
      $("cfg-stream-key").value      = "";
      $("cfg-stream-key").placeholder = streamKeyConfigured ? "Configurada; dejar vacío para conservar" : "xxxx-xxxx-xxxx-xxxx";
      $("cfg-stream-key-meta").value = "";
      $("cfg-stream-key-meta").placeholder = streamKeyMetaConfigured ? "Configurada; dejar vacío para conservar" : "xxxx-xxxx-xxxx-xxxx";
      savedCustomRtmpUrl = cfg.RTMP_URL || "";
      $("cfg-rtmp-url").value        = "";
      $("cfg-rtmp-url").placeholder = savedCustomRtmpUrl ? "Configurada; dejar vacío para conservar" : "rtmp://tu-servidor/live/key";
      updatePlatformUI($("cfg-platform").value);

      // Audio
      const noAudio = cfg.STREAM_NO_AUDIO === "true";
      $("cfg-audio-stereo").checked = (cfg.AUDIO_CHANNELS || "1") === "2";
      $("cfg-audio-rate").value     = cfg.AUDIO_RATE || "44100";
      $("cfg-audio-boost").checked  = cfg.STREAM_AUDIO_BOOST === "true";

      // GPU Encoder
      gpuEncoderPref = cfg.GPU_ENCODER === "true";
      const gpuToggleEl = $("gpu-encoder-toggle");
      if (gpuToggleEl) gpuToggleEl.checked = gpuEncoderPref;

      // Overlays — Logo
      $("cfg-overlay-logo-enabled").checked = cfg.OVERLAY_LOGO_ENABLED !== "false";
      const logoFile = cfg.OVERLAY_LOGO_FILE || "";
      $("cfg-overlay-logo-file").value = logoFile;

      const logoW = Number(cfg.OVERLAY_LOGO_W || 0);
      $("cfg-overlay-logo-w").value = logoW;
      document.querySelectorAll("#logo-w-chips .chip-btn").forEach((b) =>
        b.classList.toggle("active", Number(b.dataset.logow) === logoW)
      );

      const logoPad = Number(cfg.OVERLAY_LOGO_PAD || 20);
      $("cfg-overlay-logo-pad").value = logoPad;
      document.querySelectorAll("#logo-pad-chips .chip-btn").forEach((b) =>
        b.classList.toggle("active", Number(b.dataset.logopad) === logoPad)
      );

      setLogoPos(cfg.OVERLAY_LOGO_POS || "br");

      // Overlays — Banner
      $("cfg-overlay-banner-enabled").checked = cfg.OVERLAY_BANNER_ENABLED !== "false";
      $("cfg-overlay-banner").value = cfg.OVERLAY_BANNER || "";
      setBannerPos(cfg.OVERLAY_BANNER_POS || "footer");

      // Overlays — Texto libre
      $("cfg-overlay-text-enabled").checked = cfg.OVERLAY_TEXT_ENABLED !== "false";
      $("cfg-overlay-text").value = cfg.OVERLAY_TEXT || "";
      setTextPos(cfg.OVERLAY_TEXT_POS || "bl");

      // Overlays — Timestamp
      $("cfg-overlay-timestamp").checked = cfg.OVERLAY_TIMESTAMP === "true";
      setTimestampPos(cfg.OVERLAY_TIMESTAMP_POS || "tl");

      await loadDevices((cfg.VIDEO_SOURCE || "auto") === "auto" ? "" : cfg.VIDEO_DEVICE || "", noAudio ? "__none__" : cfg.AUDIO_SOURCE === "manual" ? cfg.AUDIO_DEVICE || "" : "");
      if (noAudio) $("cfg-audio-device").value = "__none__";
      updateAudioDeviceDetails();

      updateSummaries();
      lastSavedConfigJSON = configSnapshot();
    } catch {
      // formulario queda vacío si falla
    }
  }

  // ──────────────────────────────────────────────────
  // Logo upload
  // ──────────────────────────────────────────────────
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
      updateSummaries();
    } catch (err) {
      msgEl.textContent = err.message;
      msgEl.className = "error";
    }
    $("logo-file-input").value = "";
  });

  $("btn-upload")?.addEventListener("keydown", (ev) => {
    if (ev.key !== "Enter" && ev.key !== " ") return;
    ev.preventDefault();
    $("logo-file-input").click();
  });

  // ──────────────────────────────────────────────────
  // Login / logout
  // ──────────────────────────────────────────────────
  const loginForm = $("login-form");
  const submitLoginFromKeyboard = (ev) => {
    if (ev.key !== "Enter" || ev.isComposing || loginInFlight) return;
    ev.preventDefault();
    if (typeof loginForm.requestSubmit === "function") {
      loginForm.requestSubmit($("login-submit"));
    } else {
      $("login-submit").click();
    }
  };
  $("username").addEventListener("keydown", submitLoginFromKeyboard);
  $("password").addEventListener("keydown", submitLoginFromKeyboard);

  loginForm.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (loginInFlight) return;
    loginInFlight = true;
    $("login-error").hidden = true;
    $("username").setAttribute("aria-invalid", "false");
    $("password").setAttribute("aria-invalid", "false");
    setLoginLoading(true);
    let loginFailed = false;
    try {
      const result = await api("/api/login", {
        method: "POST",
        body: { username: $("username").value, password: $("password").value },
      });
      csrfToken = result.csrf_token;
      role      = result.role;
      $("session-info").textContent = `${result.user} (${role})`;
      showDashboard();
      buildPreviewShell();
      await refreshStatus();
      await loadConfig();
      await loadPreviewConfig();
      syncMicStream();
      startEventSource();
    } catch (err) {
      loginFailed = true;
      $("password").setAttribute("aria-invalid", "true");
      $("login-error").textContent = err.message;
      $("login-error").hidden = false;
    } finally {
      loginInFlight = false;
      setLoginLoading(false);
      if (loginFailed) focusLoginField("password");
    }
  });

  $("logout-btn").addEventListener("click", async () => {
    try { await api("/api/logout", { method: "POST" }); } catch {}
    csrfToken = null;
    role = null;
    showLogin();
  });

  async function restoreLocalSession() {
    try {
      const result = await api("/api/session");
      csrfToken = result.csrf_token;
      role = result.role;
      $("session-info").textContent = `${result.user} (${role})`;
      showDashboard();
      buildPreviewShell();
      await refreshStatus();
      await loadConfig();
      await loadPreviewConfig();
      syncMicStream();
      startEventSource();
    } catch (err) {
      // A missing/expired cookie is the normal first-visit path. Network
      // errors remain visible through the normal login screen instead of
      // creating a half-authenticated dashboard.
      csrfToken = null;
      role = null;
      focusLoginField("username");
    }
  }

  // ──────────────────────────────────────────────────
  // Construir y guardar config
  // ──────────────────────────────────────────────────
  function buildConfigBody() {
    const audioVal      = $("cfg-audio-device").value;
    const noAudio       = audioVal === "__none__";
    const platform      = $("cfg-platform").value;
    const streamKey     = $("cfg-stream-key").value.trim();
    const streamKeyMeta = $("cfg-stream-key-meta").value.trim();

    let rtmpUrl = "", rtmpUrlSecondary = "";
    if (platform === "dual") {
      rtmpUrl          = PLATFORM_BASE.youtube  + streamKey;
      rtmpUrlSecondary = PLATFORM_BASE.facebook + streamKeyMeta;
    } else if (platform === "custom") {
      rtmpUrl = $("cfg-rtmp-url").value.trim() || savedCustomRtmpUrl;
    } else {
      rtmpUrl = (PLATFORM_BASE[platform] || "") + streamKey;
    }

    return {
      platform,
      stream_key:          streamKey,
      stream_key_meta:     streamKeyMeta,
      rtmp_url:            rtmpUrl,
      rtmp_url_secondary:  rtmpUrlSecondary,
      width:               Number($("cfg-width").value),
      height:              Number($("cfg-height").value),
      fps:                 Number($("cfg-fps").value),
      bitrate:             Number($("cfg-bitrate").value),
      preset:              $("cfg-preset").value,
      video_source:        $("cfg-video-device").value ? "v4l2" : "auto",
      video_device:        $("cfg-video-device").value,
      audio_source:        noAudio || !audioVal ? "auto" : "manual",
      audio_device:        noAudio ? "" : audioVal,
      audio_channels:      $("cfg-audio-stereo").checked ? 2 : 1,
      audio_rate:          Number($("cfg-audio-rate").value),
      stream_no_audio:     noAudio,
      stream_audio_boost:  $("cfg-audio-boost").checked,
      gpu_encoder:         gpuEncoderPref,
      // El valor de cada overlay se guarda siempre (aunque su toggle esté apagado) para
      // no perderlo — solo el *_enabled decide si se renderiza en el stream/preview.
      overlay_logo_enabled: $("cfg-overlay-logo-enabled").checked,
      overlay_logo_file:   $("cfg-overlay-logo-file").value.trim(),
      overlay_logo_pos:    $("cfg-overlay-logo-pos").value,
      overlay_logo_pad:    Number($("cfg-overlay-logo-pad").value) || 20,
      overlay_logo_w:      Number($("cfg-overlay-logo-w").value)   || 0,
      overlay_banner_enabled: $("cfg-overlay-banner-enabled").checked,
      overlay_banner:      $("cfg-overlay-banner").value.trim().replace(/[\r\n]+/g, " ").slice(0, 200),
      overlay_banner_pos:  $("cfg-overlay-banner-pos").value,
      overlay_text_enabled: $("cfg-overlay-text-enabled").checked,
      overlay_text:        $("cfg-overlay-text").value.trim().replace(/[\r\n]+/g, " ").slice(0, 200),
      overlay_text_pos:    $("cfg-overlay-text-pos").value,
      overlay_timestamp:   $("cfg-overlay-timestamp").checked,
      overlay_timestamp_pos: $("cfg-overlay-timestamp-pos").value,
    };
  }

  // "Hay algún overlay que efectivamente se va a renderizar" — usado para decidir
  // el servicio a arrancar (streaming vs streaming-overlay) y el preview.
  function anyOverlayActive() {
    const logoOn   = $("cfg-overlay-logo-enabled")?.checked   && $("cfg-overlay-logo-file").value.trim();
    const bannerOn = $("cfg-overlay-banner-enabled")?.checked && $("cfg-overlay-banner").value.trim();
    const textOn   = $("cfg-overlay-text-enabled")?.checked   && $("cfg-overlay-text").value.trim();
    const tsOn     = $("cfg-overlay-timestamp")?.checked;
    return Boolean(logoOn || bannerOn || textOn || tsOn);
  }

  // Snapshot del formulario para detectar cambios sin guardar. Se actualiza
  // después de cargar la config persistida y después de guardarla con éxito.
  function configSnapshot() {
    return JSON.stringify(buildConfigBody());
  }

  function hasUnsavedChanges() {
    return lastSavedConfigJSON !== null && configSnapshot() !== lastSavedConfigJSON;
  }

  // Antes de iniciar stream o preview: si hay cambios sin guardar, confirmar
  // que el usuario quiere continuar con la última configuración guardada.
  function confirmStartWithUnsavedChanges() {
    if (!hasUnsavedChanges()) return true;
    return confirm(
      "Hay cambios sin guardar en la configuración.\n\n" +
      "Si continúas, se usará la última configuración guardada (no la que ves en el formulario).\n\n" +
      "¿Iniciar de todas formas?"
    );
  }

  function validateConfig(intended) {
    const ranges = [
      ["ancho", intended.width, 320, 1920],
      ["alto", intended.height, 240, 1080],
      ["FPS", intended.fps, 1, 60],
      ["bitrate", intended.bitrate, 200000, 25000000],
    ];
    for (const [label, value, min, max] of ranges) {
      if (!Number.isFinite(value) || value < min || value > max) {
        throw new Error(`Revisa el ${label}: debe estar entre ${min} y ${max}.`);
      }
    }
    if (intended.platform === "custom" && !intended.rtmp_url) {
      throw new Error("Escribe una URL RTMP personalizada.");
    }
    // Empty secret fields preserve the values already stored on the Raspi.
  }

  function verifyPersistedConfig(intended, persisted) {
    const checks = [
      ["STREAM_WIDTH", String(intended.width)],
      ["STREAM_HEIGHT", String(intended.height)],
      ["STREAM_FPS", String(intended.fps)],
      ["STREAM_BITRATE", String(intended.bitrate)],
      ["STREAM_PRESET", intended.preset],
      ["VIDEO_SOURCE", intended.video_source],
      ["VIDEO_DEVICE", intended.video_source === "auto" ? "" : intended.video_device],
      ["AUDIO_CHANNELS", String(intended.audio_channels)],
      ["AUDIO_RATE", String(intended.audio_rate)],
      ["STREAM_NO_AUDIO", intended.stream_no_audio ? "true" : "false"],
      ["STREAM_AUDIO_BOOST", intended.stream_audio_boost ? "true" : "false"],
      ["GPU_ENCODER", intended.gpu_encoder ? "true" : "false"],
      ["OVERLAY_LOGO_ENABLED", intended.overlay_logo_enabled ? "true" : "false"],
      ["OVERLAY_LOGO_FILE", intended.overlay_logo_file],
      ["OVERLAY_LOGO_POS", intended.overlay_logo_pos],
      ["OVERLAY_LOGO_PAD", String(intended.overlay_logo_pad)],
      ["OVERLAY_LOGO_W", String(intended.overlay_logo_w)],
      ["OVERLAY_BANNER_ENABLED", intended.overlay_banner_enabled ? "true" : "false"],
      ["OVERLAY_BANNER", intended.overlay_banner],
      ["OVERLAY_BANNER_POS", intended.overlay_banner_pos],
      ["OVERLAY_TEXT_ENABLED", intended.overlay_text_enabled ? "true" : "false"],
      ["OVERLAY_TEXT", intended.overlay_text],
      ["OVERLAY_TEXT_POS", intended.overlay_text_pos],
      ["OVERLAY_TIMESTAMP", intended.overlay_timestamp ? "true" : "false"],
      ["OVERLAY_TIMESTAMP_POS", intended.overlay_timestamp_pos],
    ];
    const expectedAudio = intended.stream_no_audio ? "" : intended.audio_device;
    checks.push(["AUDIO_SOURCE", intended.audio_source]);
    checks.push(["AUDIO_DEVICE", expectedAudio]);

    for (const [key, expected] of checks) {
      if ((persisted[key] || "") !== (expected || "")) {
        throw new Error(`La configuración se guardó, pero ${key} quedó como "${persisted[key] || ""}" en vez de "${expected || ""}".`);
      }
    }
  }

  $("config-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const msgEl = $("config-msg");
    const saveBtn = ev.currentTarget.querySelector('button[type="submit"]');
    msgEl.hidden = true;
    saveBtn.disabled = true;
    saveBtn.setAttribute("aria-busy", "true");
    try {
      const intended = buildConfigBody();
      validateConfig(intended);
      msgEl.textContent = "Guardando y verificando...";
      msgEl.className = "device-status";
      msgEl.hidden = false;
      await api("/api/config", { method: "PUT", body: intended });
      const persisted = await api("/api/config");
      verifyPersistedConfig(intended, persisted);
      await loadConfig();
      msgEl.textContent = "Guardado y verificado.";
      msgEl.className = "";
      msgEl.hidden = false;
    } catch (err) {
      msgEl.textContent = err.message;
      msgEl.className = "error";
      msgEl.hidden = false;
    } finally {
      saveBtn.disabled = false;
      saveBtn.setAttribute("aria-busy", "false");
    }
  });

  restoreLocalSession();
})();
