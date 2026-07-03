# Building & distributing Neev Remote

Three distributable forms: **web** (no install), **installer**, and **portable**.

## 0. Build everything via CI (recommended)

You don't need to own every OS. The GitHub Actions workflow
`.github/workflows/flutter.yml` builds **all** packages on native runners
(Windows installer+portable, macOS dmg+zip, Linux tar.gz, web zip):

- Push to `main` or run it manually (**Actions → Build Flutter Desktop App →
  Run workflow**) to get downloadable build artifacts.
- Push a tag `flutter-vX.Y.Z` to publish them to a **GitHub Release**.

The sections below are for building locally on one OS at a time.

## 1. Build locally

| Target | Command (run on that OS) | Outputs in `dist/` |
|---|---|---|
| Windows | `powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1` | `NeevRemote-Setup-x64.exe` (installer), `NeevRemote-windows-x64-portable.zip` |
| macOS | `packaging/build_macos.sh` | `NeevRemote-macos.pkg` + `.dmg` (installers), `NeevRemote-macos.zip` (portable) |
| Linux | `packaging/build_linux.sh` | `NeevRemote-linux-x64.tar.gz` (portable) |
| Web | `flutter build web --release` | `build/web/` (static site) |

> Each desktop build must run on its own OS — Flutter cannot cross-compile
> desktop binaries. Windows needs Visual Studio "Desktop development with C++";
> the optional installer needs [Inno Setup](https://jrsoftware.org/isdl.php).
> macOS needs full Xcode. Linux needs `libgtk-3-dev libx11-dev libxtst-dev`.

## 2. Publish to the download website

The Go server (`server/`) already serves a public download portal — no code
changes needed:

- `GET /api/v1/public/flutter-installers` → JSON list of files in `flutter-downloads/`
- `GET /api/v1/public/flutter-installers/<file>` → the download
- The web dashboard lists them under its downloads page.

So to publish a new release, copy the built artifacts into the repo's
`flutter-downloads/` directory (served automatically):

```bash
cp neev_remote/dist/* flutter-downloads/
```

For Docker deployments, mount the folder into the server container (see the
top-level `docker-compose.yml`), then restart.

## 3. Host the web app (no-install viewer/client)

`flutter build web --release` produces `build/web/`. Serve it from any static
host, or via the Go server which already serves `./public`:

```bash
cp -r neev_remote/build/web/* public/
# users open https://your-domain/ and use the viewer/client in the browser
```

> The web build is a real viewer **and** host (screen capture uses the browser's
> getDisplayMedia picker). Native mouse/keyboard *injection* only applies to the
> desktop builds; the web build views and shares but can't inject OS input.

## End-user instructions (what to tell your users)

1. Go to your download page and pick your OS.
2. **Installer**: run it (Windows `.exe` / macOS `.dmg` → drag to Applications).
   **Portable**: unzip and run `neev_remote` — no install.
3. To **share your screen**: open **Agent**, click **Start Agent**, share the ID +
   password. To **control another machine**: open **Viewer**, enter the ID +
   password, **Connect**.
4. First run prompts for OS permissions on the host (macOS: Screen Recording +
   Accessibility).
