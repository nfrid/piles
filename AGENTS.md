# AGENTS.md

- This is a small macOS Swift package. Core code lives in `Sources/`, the app entry point is `Entry/main.swift`, and tests are a custom executable in `Tests/`.
- Use `make agent-test` for verification (and `make agent-build` for a release build). These pass `--disable-sandbox` to SwiftPM so builds work in Cursor's agent sandbox; prefer them over `make test` / `make build`, which use SwiftPM's normal sandbox and fail or need `required_permissions: ["all"]` there. Humans should use `make test` and `make build` locally.
- Keep pure layout logic in `Tiler`; avoid adding AppKit or Accessibility API dependencies there.
- Treat `WindowManager`, `WindowObserver`, and `Hotkeys` as system-boundary code. Be careful with Accessibility API return values, event tap ownership, thread/main-run-loop behavior, and macOS permission failures.
- Prefer small, focused changes. This project intentionally avoids heavy dependencies and framework ceremony.
