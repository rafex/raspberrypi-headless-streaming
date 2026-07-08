FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

WORKDIR /app

COPY pyproject.toml uv.lock ./
COPY src ./src

RUN uv sync --frozen --no-dev --no-cache

EXPOSE 8080

CMD ["uv", "run", "--no-dev", "uvicorn", "streaming_api.app:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers"]
