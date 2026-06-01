# AGENTS.md

- This is a small macOS Swift package. Core code lives in `Sources/`, the app entry point is `Entry/main.swift`, and tests are a custom executable in `Tests/`.
- Use `make test` for the fast check and `make build` for the release app build. The tests build and run `.build/debug/piles-tests`.
- Keep pure layout logic in `Tiler`; avoid adding AppKit or Accessibility API dependencies there.
- Treat `WindowManager`, `WindowObserver`, and `Hotkeys` as system-boundary code. Be careful with Accessibility API return values, event tap ownership, thread/main-run-loop behavior, and macOS permission failures.
- Prefer small, focused changes. This project intentionally avoids heavy dependencies and framework ceremony.
