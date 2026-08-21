(() => {
  "use strict";

  class StreamingApiError extends Error {
    constructor(message, { status = 0, code = "http", path = "" } = {}) {
      super(message);
      this.name = "StreamingApiError";
      this.status = status;
      this.code = code;
      this.path = path;
    }
  }

  window.createStreamingApiClient = function createStreamingApiClient({
    basePath = "",
    getHeaders = () => ({}),
    credentials = "same-origin",
    timeoutMs = 15_000,
  } = {}) {
    const inFlight = new Map();

    async function request(path, { method = "GET", body, formData = false, dedupe = method === "GET" } = {}) {
      const key = `${method}:${path}`;
      if (dedupe && inFlight.has(key)) return inFlight.get(key);
      const promise = (async () => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        const headers = { ...getHeaders(method, formData) };
        if (!formData && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
        try {
          const response = await fetch(`${basePath}${path}`, {
            method, headers, credentials,
            body: formData ? body : body == null ? undefined : JSON.stringify(body),
            signal: controller.signal,
          });
          const data = await response.json().catch(() => ({}));
          if (!response.ok) {
            const code = response.status === 401 ? "unauthorized" :
              response.status >= 500 ? (path.includes("/ui/api/raspi/") ? "raspi-unavailable" : "backend-unavailable") : "http";
            throw new StreamingApiError(data.error || data.detail || `Error ${response.status}`, {
              status: response.status, path, code,
            });
          }
          return data;
        } catch (error) {
          if (error instanceof StreamingApiError) throw error;
          if (error.name === "AbortError") throw new StreamingApiError("La solicitud tardó demasiado.", { code: "timeout", path });
          throw new StreamingApiError("No se pudo conectar con el servicio.", { code: "network", path });
        } finally { clearTimeout(timer); }
      })();
      if (dedupe) { inFlight.set(key, promise); promise.finally(() => inFlight.delete(key)).catch(() => {}); }
      return promise;
    }
    return { request, StreamingApiError };
  };
})();
