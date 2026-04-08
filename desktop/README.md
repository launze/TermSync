# TTY1 Desktop

Cross-platform terminal emulator desktop client built with Rust and Tauri.

## Prerequisites

- Rust 1.70+
- Node.js 18+
- Tauri CLI

## Setup

```bash
# Install Tauri CLI
cargo install tauri-cli --version "^2.0"

# Run in development mode
cd src-tauri
cargo tauri dev

# Build release
cargo tauri build
```

## Features

- Multi-tab terminal
- Split screen layout
- Real-time sync with mobile
- WSS connection with self-signed certificate support
