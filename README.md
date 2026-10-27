# Print Lab

A macOS app for printing photos on Canon photo printers. An open alternative to Canon's Professional Print & Layout.

![Print Lab with a sunset photo on A4 Hahnemühle Photo Rag](docs/screenshot.png)

- **Layouts:** one image per sheet, grids, contact sheets with captions. Drag to move the crop, drop images onto cells.
- **Color:** 16-bit conversion into the paper profile, softproof with paper white. Canon's profiles per media type, or the paper maker's own (e.g. Tecco, Hahnemühle).
- **Printing:** straight to Canon's driver with the right media type, quality and margins.
- **Printer status:** ink levels, Wi-Fi signal, maintenance cartridge, and errors with Canon's support code and help link.
- **Remote control:** scripts can set up a sheet via `printlab://`. Printing stays a button press.

Print Lab is not affiliated with Canon.

## Install

```
brew install yannickpulver/tap/print-lab
```

Needs macOS 26, Canon's IJ driver for your printer, and the printer added in System Settings → Printers & Scanners. Tested on the PRO-1000; other IJ printers (e.g. PRO-300, PRO-200) get their options from their own driver.

## Remote control

```
open "printlab://configure?clear=1&paper=A3&media=Baryta&template=grid&rows=1&columns=2&image=/path/a.tif&image=/path/b.tif"
cat ~/Library/Application\ Support/PrintLab/state.json
```

`state.json` holds the current settings, valid option values and errors. The keys are listed in `RemoteControl.swift`.

## Build

Needs Xcode 27 and [Tuist](https://tuist.dev).

```
tuist generate
xcodebuild -workspace PrintLab.xcworkspace -scheme PrintLab test
```

## License

MIT
