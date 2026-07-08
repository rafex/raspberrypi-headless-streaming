from __future__ import annotations

import uvicorn


def main() -> None:
    uvicorn.run("streaming_api.app:app", host="0.0.0.0", port=8080, proxy_headers=True)


if __name__ == "__main__":
    main()
