(() => {
  "use strict";

  let csrfToken = null;
  let role = null;
  let eventSource = null;
  let overlayPref = true;

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

  async function api(path, { method = "GET", body } = {}) {
    const headers = { "Content-Type": "application/json" };
    if (csrfToken && method !== "GET") headers["X-CSRF-Token"] = csrfToken;
    const res = await fetch(path, {
      method, headers, credentials: "same-origin",
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

    if (role === "operator") {
      $("global-actions").innerHTML = `
        <button id="btn-global-stop-all" class="btn-stop-all global-stop">Stop all</button>
      `;
      document.getElementById("btn-global-stop-all")?.addEventListener("click", (e) =>
        handleStopAll(e.currentTarget)
      );
    } else {
      $("global-actions").innerHTML = "";
    }

    $("services").innerHTML = `
      <div class="service-card">
        <div class="name">Stream</div>
        <span class="badge ${isActive ? "active" : "inactive"}">
          ${isActive ? "Activo" + (withOverlay ? " — con overlay" : "") : "Detenido"} — ${state}
        </span>
        ${role === "operator" ? `
          <div class="service-actions">
            <button id="btn-stream-start" class="btn-start" ${isActive ? "disabled" : ""}>Iniciar</button>
            <button id="btn-stream-stop"  class="btn-stop"  ${!isActive ? "disabled" : ""}>Detener</button>
          </div>` : ""}
      </div>`;

    if (role === "operator") {
      // Mientras el stream esté activo, el toggle de Overlays refleja la
      // realidad (no se puede cambiar sin reiniciar) en vez del preference local.
      const toggle = $("overlay-enabled-toggle");
      if (toggle) {
        if (isActive) toggle.checked = withOverlay;
        overlayPref = toggle.checked;
      }
      document.getElementById("btn-stream-start")?.addEventListener("click", (e) =>
        handleStreamAction(overlayPref ? "streaming-overlay" : "streaming", "start", e.currentTarget)
      );
      document.getElementById("btn-stream-stop")?.addEventListener("click", (e) =>
        handleStreamAction(activeService || "streaming", "stop", e.currentTarget)
      );
    }
  }

  // Deshabilita el botón clickeado de inmediato (antes de esperar la red) para
  // que un doble-click no dispare dos requests concurrentes — start/stop ya
  // son idempotentes en el backend, pero esto evita el parpadeo de la UI y
  // gastar sudo de más mientras se espera la respuesta.
  async function handleStreamAction(service, action, btn) {
    if (btn) btn.disabled = true;
    try {
      await api(`/api/stream/${service}/${action}`, { method: "POST" });
    } catch (err) {
      alert(err.message);
    } finally {
      await refreshStatus();
    }
  }

  async function handleStopAll(btn) {
    if (btn) btn.disabled = true;
    try {
      await api("/api/stream/stop-all", { method: "POST" });
    } catch (err) {
      alert(err.message);
    } finally {
      await refreshStatus();
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
    } catch { showLogin(); }
  }

  function startEventSource() {
    if (eventSource) eventSource.close();
    eventSource = new EventSource("/api/events");
    eventSource.onmessage = (e) => {
      try {
        const data = JSON.parse(e.data);
        renderServices(data);
        updatePreviewStatus(data["preview"]);
        lockOverlayToggle(anyServiceActive(data));
      } catch {}
    };
    eventSource.onerror = () => {
      eventSource.close(); eventSource = null;
      // Verificar si la sesión sigue activa o si es un error transitorio (429, red, etc.)
      fetch("/api/status", { credentials: "same-origin" }).then((r) => {
        if (r.status === 401) { showLogin(); return; }
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
        <p class="field-hint">El toggle "Aplicar overlay" del paso 5 (Overlays) también controla este preview.</p>
        <p class="field-hint" id="preview-vlc-hint"></p>
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
    $("btn-preview-start").addEventListener("click", (e) => handlePreviewStart(e.currentTarget));
    $("btn-preview-stop").addEventListener("click", (e) => handleStreamAction("preview", "stop", e.currentTarget));
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
    let hint = "";
    if (t === "rtmp")      hint = `Ver con VLC: vlc rtmp://${host}:1935/${name}`;
    else if (t === "tcp")  hint = `Ver con VLC (después de iniciar): vlc tcp://${host}:${port}`;
    else                   hint = `Ver con VLC en el cliente: vlc udp://@:${port}`;
    $("preview-vlc-hint").textContent = hint;
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
    try {
      const transport = $("preview-transport").value;
      await api("/api/preview/config", {
        method: "PUT",
        body: {
          transport,
          port:      Number($("preview-port").value) || (transport === "rtmp" ? 1935 : 1234),
          client_ip: $("preview-client-ip").value.trim(),
          rtmp_name: $("preview-rtmp-name").value.trim() || "preview",
          overlay:   overlayPref,
        },
      });
      await api("/api/stream/preview/start", { method: "POST" });
    } catch (err) {
      alert(err.message);
    } finally {
      await refreshStatus();
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
    document.querySelectorAll(".pos-btn[data-logopos]").forEach((b) =>
      b.classList.toggle("active", b.dataset.logopos === pos)
    );
  }

  document.querySelectorAll(".pos-btn[data-logopos]").forEach((btn) => {
    btn.addEventListener("click", () => setLogoPos(btn.dataset.logopos));
  });

  // ──────────────────────────────────────────────────
  // Text position — 3×3 grid
  // ──────────────────────────────────────────────────
  function setTextPos(pos) {
    $("cfg-overlay-text-pos").value = pos;
    document.querySelectorAll(".pos-btn[data-textpos]").forEach((b) =>
      b.classList.toggle("active", b.dataset.textpos === pos)
    );
  }

  document.querySelectorAll(".pos-btn[data-textpos]").forEach((btn) => {
    btn.addEventListener("click", () => setTextPos(btn.dataset.textpos));
  });

  // ──────────────────────────────────────────────────
  // Banner position — footer / header buttons
  // ──────────────────────────────────────────────────
  function setBannerPos(pos) {
    $("cfg-overlay-banner-pos").value = pos;
    document.querySelectorAll(".banner-pos-btn").forEach((b) =>
      b.classList.toggle("active", b.dataset.bannerpos === pos)
    );
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

    // Overlays
    const parts = [
      $("cfg-overlay-logo-file").value.trim() && "Logo",
      $("cfg-overlay-banner").value.trim()    && "Banner",
      $("cfg-overlay-text").value.trim()      && "Texto",
      $("cfg-overlay-timestamp").checked      && "Hora",
    ].filter(Boolean);
    $("sum-overlay").textContent = parts.length ? parts.join(" · ") : "Ninguno";
  }

  ["cfg-audio-rate", "cfg-preset"].forEach((id) => {
    $(id)?.addEventListener("change", updateSummaries);
  });
  ["cfg-audio-stereo", "cfg-audio-boost", "cfg-overlay-timestamp"].forEach((id) => {
    $(id)?.addEventListener("change", updateSummaries);
  });
  ["cfg-overlay-logo-file", "cfg-overlay-banner", "cfg-overlay-text"].forEach((id) => {
    $(id)?.addEventListener("input", updateSummaries);
  });

  // Toggle único "Aplicar overlay": controla tanto el botón Iniciar (Stream)
  // como Iniciar preview. Se deshabilita mientras cualquiera de los dos esté
  // activo (ver lockOverlayToggle, llamado desde refreshStatus/SSE).
  overlayPref = $("overlay-enabled-toggle")?.checked ?? true;
  $("overlay-enabled-toggle")?.addEventListener("change", (e) => {
    overlayPref = e.target.checked;
  });

  function lockOverlayToggle(anyActive) {
    const toggle = $("overlay-enabled-toggle");
    if (toggle) toggle.disabled = anyActive;
  }

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

  async function loadDevices(currentVideo, currentAudio) {
    const statusEl = $("device-status");
    statusEl.textContent = "Escaneando...";
    try {
      const { cameras, mics } = await api("/api/devices");
      populateDeviceSelect($("cfg-video-device"), cameras, currentVideo);
      populateDeviceSelect($("cfg-audio-device"), mics,    currentAudio);
      statusEl.textContent =
        `${cameras.length} cámara(s) · ${mics.length} micrófono(s)` +
        (cameras.length === 0 ? " — no se detectaron cámaras" : "");
      updateAudioDeviceDetails();
      updateSummaries();
    } catch (err) {
      statusEl.textContent = `Error al escanear: ${err.message}`;
    }
  }

  $("btn-scan-devices").addEventListener("click", () => loadDevices("", ""));

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
      let streamKey    = cfg.STREAM_KEY      || "";
      let streamKeyMeta = cfg.STREAM_KEY_META || "";
      if (!platform) {
        const det = detectPlatform(cfg.RTMP_URL || "");
        platform  = det.platform;
        streamKey = det.key;
      }
      if (cfg.STREAM_DUAL === "true") platform = "dual";
      $("cfg-platform").value        = platform || "youtube";
      $("cfg-stream-key").value      = streamKey;
      $("cfg-stream-key-meta").value = streamKeyMeta;
      $("cfg-rtmp-url").value        = cfg.RTMP_URL || "";
      updatePlatformUI($("cfg-platform").value);

      // Audio
      const noAudio = cfg.STREAM_NO_AUDIO === "true";
      $("cfg-audio-stereo").checked = (cfg.AUDIO_CHANNELS || "1") === "2";
      $("cfg-audio-rate").value     = cfg.AUDIO_RATE || "44100";
      $("cfg-audio-boost").checked  = cfg.STREAM_AUDIO_BOOST === "true";

      // Overlays — Logo
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
      $("cfg-overlay-banner").value = cfg.OVERLAY_BANNER || "";
      setBannerPos(cfg.OVERLAY_BANNER_POS || "footer");

      // Overlays — Texto libre
      $("cfg-overlay-text").value = cfg.OVERLAY_TEXT || "";
      setTextPos(cfg.OVERLAY_TEXT_POS || "bl");

      // Overlays — Timestamp
      $("cfg-overlay-timestamp").checked = cfg.OVERLAY_TIMESTAMP === "true";

      await loadDevices(cfg.VIDEO_DEVICE || "", noAudio ? "__none__" : cfg.AUDIO_DEVICE || "");
      if (noAudio) $("cfg-audio-device").value = "__none__";
      updateAudioDeviceDetails();

      updateSummaries();
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

  // ──────────────────────────────────────────────────
  // Login / logout
  // ──────────────────────────────────────────────────
  $("login-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    $("login-error").hidden = true;
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
      startEventSource();
    } catch (err) {
      $("login-error").textContent = err.message;
      $("login-error").hidden = false;
    }
  });

  $("logout-btn").addEventListener("click", async () => {
    try { await api("/api/logout", { method: "POST" }); } catch {}
    csrfToken = null;
    role = null;
    showLogin();
  });

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
      rtmpUrl = $("cfg-rtmp-url").value.trim();
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
      video_device:        $("cfg-video-device").value,
      audio_device:        noAudio ? "" : audioVal,
      audio_channels:      $("cfg-audio-stereo").checked ? 2 : 1,
      audio_rate:          Number($("cfg-audio-rate").value),
      stream_no_audio:     noAudio,
      stream_audio_boost:  $("cfg-audio-boost").checked,
      overlay_logo_file:   $("cfg-overlay-logo-file").value.trim(),
      overlay_logo_pos:    $("cfg-overlay-logo-pos").value,
      overlay_logo_pad:    Number($("cfg-overlay-logo-pad").value) || 20,
      overlay_logo_w:      Number($("cfg-overlay-logo-w").value)   || 0,
      overlay_banner:      $("cfg-overlay-banner").value.trim().replace(/[\r\n]+/g, " ").slice(0, 200),
      overlay_banner_pos:  $("cfg-overlay-banner-pos").value,
      overlay_text:        $("cfg-overlay-text").value.trim().replace(/[\r\n]+/g, " ").slice(0, 200),
      overlay_text_pos:    $("cfg-overlay-text-pos").value,
      overlay_timestamp:   $("cfg-overlay-timestamp").checked,
    };
  }

  function verifyPersistedConfig(intended, persisted) {
    const checks = [
      ["STREAM_WIDTH", String(intended.width)],
      ["STREAM_HEIGHT", String(intended.height)],
      ["STREAM_FPS", String(intended.fps)],
      ["STREAM_BITRATE", String(intended.bitrate)],
      ["STREAM_PRESET", intended.preset],
      ["VIDEO_DEVICE", intended.video_device],
      ["AUDIO_CHANNELS", String(intended.audio_channels)],
      ["AUDIO_RATE", String(intended.audio_rate)],
      ["STREAM_NO_AUDIO", intended.stream_no_audio ? "true" : "false"],
      ["STREAM_AUDIO_BOOST", intended.stream_audio_boost ? "true" : "false"],
      ["OVERLAY_LOGO_FILE", intended.overlay_logo_file],
      ["OVERLAY_LOGO_POS", intended.overlay_logo_pos],
      ["OVERLAY_LOGO_PAD", String(intended.overlay_logo_pad)],
      ["OVERLAY_LOGO_W", String(intended.overlay_logo_w)],
      ["OVERLAY_BANNER", intended.overlay_banner],
      ["OVERLAY_BANNER_POS", intended.overlay_banner_pos],
      ["OVERLAY_TEXT", intended.overlay_text],
      ["OVERLAY_TEXT_POS", intended.overlay_text_pos],
      ["OVERLAY_TIMESTAMP", intended.overlay_timestamp ? "true" : "false"],
    ];
    const expectedAudio = intended.stream_no_audio ? "" : intended.audio_device;
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
    msgEl.hidden = true;
    try {
      const intended = buildConfigBody();
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
    }
  });
})();
