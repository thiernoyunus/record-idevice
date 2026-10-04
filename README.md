<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/header/graph.svg?title=Record+iDevice&subtitle=Mirror+and+record+your+iPhone+or+iPad+on+your+Mac&logo=apple&mode=dark" />
    <img alt="Record iDevice" src="https://shieldcn.dev/header/graph.svg?title=Record+iDevice&subtitle=Mirror+and+record+your+iPhone+or+iPad+on+your+Mac&logo=apple&mode=light" />
  </picture>
</p>

<p align="center">
  <a href="https://github.com/thiernoyunus/record-idevice/releases/latest"><img alt="Latest release" src="https://shieldcn.dev/github/release/thiernoyunus/record-idevice.svg?variant=secondary" /></a>
  <a href="https://github.com/thiernoyunus/record-idevice/actions/workflows/build.yml"><img alt="CI status" src="https://shieldcn.dev/github/ci/thiernoyunus/record-idevice.svg?variant=secondary&workflow=build.yml" /></a>
  <a href="LICENSE"><img alt="License" src="https://shieldcn.dev/github/license/thiernoyunus/record-idevice.svg?variant=secondary" /></a>
  <img alt="macOS 15+" src="https://shieldcn.dev/badge/macOS-15%2B-black.svg?variant=secondary&logo=apple" />
</p>

A native Mac app that shows your iPhone or iPad screen in a clean window and
records it together with your Mac's camera and microphone — perfect for app
demos and talking-head walkthroughs.

## Features

- **Mirror over USB** — plug in your phone and it appears instantly. Your phone
  stays unlocked and usable, and its sound is recorded cleanly.
- **Mirror wirelessly** — pick **Record iDevice** in Control Center → Screen
  Mirroring (video only for now).
- **Camera bubble** — your face in a draggable, resizable bubble over the phone.
- **Polished look** — device frame, gradient and wallpaper backgrounds,
  vertical (9:16) or horizontal (16:9) canvas.
- **Editor** — trim, add smooth zoom-ins, and tweak the look after recording,
  without touching the original footage.
- **Screenshots** — press ⌘S for a full-resolution shot.
- **Auto-updates** built in.

## Download

Grab the latest `Record-iDevice.zip` from
[Releases](https://github.com/thiernoyunus/record-idevice/releases/latest),
unzip it, and drag **Record iDevice** into Applications. Requires macOS 15 or
later.

For USB mirroring, your phone must be unlocked and you need to tap **Trust This
Computer** the first time — same as QuickTime.

## Build from source

Requires Xcode (with the macOS SDK), plus a few tools for the wireless helper:

```bash
brew install cmake pkg-config openssl@3 libplist
```

```bash
./build.sh
```

The app lands in `dist/Record iDevice.app`.

## License

[GPL-3.0](LICENSE). Wireless mirroring is built on
[UxPlay](https://github.com/FDH2/UxPlay) — see [THIRD_PARTY.md](THIRD_PARTY.md).
