# Print Lab – Tasks

## Setup
- [x] Color path verified without paper: pixels tagged sRGB pass macOS + Canon filter chain bit-exact (16-bit)
- [x] Tuist project, macOS 26, Swift 6, tests target
- [x] README, LICENSE (MIT), .gitignore
- [x] Canon driver queue pointed at the printer over Wi-Fi (`ipp://<printer-ip>/ipp/print`, fixed IP via DHCP reservation)

## Printer
- [x] PPD parser: options, page sizes (dimension + imageable area), UIConstraints, cupsICCProfile
- [x] Canon driver model: media types, qualities, paper sizes, media → ICC profile mapping
- [x] Find Canon driver queues via CUPS
- [x] Printer status via IPP: state, reasons, ink levels + colors

## Color
- [x] Load images (TIFF/JPEG/PNG/HEIC/PSD) at 16 bit with their profile, EXIF orientation
- [x] ColorSync transform: source → paper profile (intent + BPC)
- [x] Softproof: paper → display, optional paper white
- [x] Black point compensation aims at the black the paper conversion reaches (Canon matte profiles printed source black at device ~6000, proofs looked lifted)
- [ ] Check on paper: Highest Density Fine Art + BPC prints deeper blacks than 0.1.7, shadows match the proof

## Layout
- [x] Sheet model: paper, orientation, borderless, margins, placed images (fill/fit, rotation, crop pan)
- [x] Templates: single, grid n×m with gap, contact sheet with captions

## Print
- [x] Render sheet to PDF (converted images tagged sRGB = handoff space), images at 600 ppi max
- [x] Submit via libcups with Canon options, track job state
- [x] Integration test: PDF → cgpdftoraster → pixels equal converted values (±2 of 65535)

## UI
- [x] Library sidebar with drag & drop, open files from Finder / Dock
- [x] Sheet canvas: select, drag to pan crop, drop image onto cell
- [x] Inspector: printer, paper, layout, color, print
- [x] Toolbar: softproof toggle, printer status
- [x] Presets (save/load settings)

## Remote control
- [x] `printlab://configure?…` sets images, paper, media, quality, layout, color, per-cell fit/turns/crop
- [x] `state.json` in Application Support with settings, cells, conflicts, printer status, option lists, last command errors
- [x] No print command on purpose: printing is a button press

## Profiles
- [x] Third-party ICC profiles: picker (installed printer profiles + file), remote key `profile`
- [x] Tecco PD190 Duo Matt: `TECCO_pro1000_PD190_HWFAP.icc` (Tecco package via dinax.com), media type Heavyweight Fine Art Paper, installed in ~/Library/ColorSync/Profiles

## Printer status
- [x] Support code + message from the printer's Remote UI (`JS_MDL/model.js`), Canon help link, Wi-Fi signal
- [x] Printer-side job state: banner "Job paused on the printer" when the printer stopped a job
- [x] Banner above the sheet + red toolbar state for printer errors (e.g. 1250 output tray closed)
- [ ] "Done" comes too early: printer reports the job completed when all data arrived, ~10 min before the paper is out, and says "idle" over IPP while printing. Log Remote UI + IPP during the next print, then show "Printing…" until the paper is out

## Margins
- [x] Free margins in mm; printer mode follows automatically (Fine Art 25 mm → Standard → Borderless)
- [x] Fine art below 25 mm: Cancel Margin Regulation + note; borderless without bleed keeps margins exact (extension 0)
- [ ] Check on paper: borderless with extension 0 keeps margins exact (e.g. Luster, 2 mm)

## Distribution
- [x] `VERSION` file as single source, CI build number as CFBundleVersion
- [x] GitHub Actions: test, build, Developer ID signing, notarization, release zip (only for new versions)
- [x] Tap workflow writes `Casks/print-lab.rb` in yannickpulver/homebrew-tap
- [x] Local check: Release build signs with Developer ID + hardened runtime, cask Ruby syntax OK, actionlint clean
- [x] Sparkle 2.10: update check in Release builds, "Check for Updates…" menu, signed appcast per release, cask `auto_updates`
- [x] Local check: Sparkle helpers sign inside-out, app verifies, sign_update signs the zip with the keychain key
- [x] `scripts/setup-release-secrets.sh`: wizard that sets all secrets and checks each value
- [x] Repo secrets set (APPLE_CERTIFICATE_BASE64, APPLE_CERTIFICATE_PASSWORD, APPLE_ID, APPLE_APP_PASSWORD, HOMEBREW_TAP_TOKEN, SPARKLE_PRIVATE_KEY; APPLE_TEAM_ID is set)
- [x] First release v0.1.0 through CI, `brew install yannickpulver/tap/print-lab` works (notarized, Gatekeeper accepts)

## UI
- [x] Print confirmation dialog with a summary, no print button in the toolbar
- [x] Presets as a dropdown on top (active preset, save as new, delete)
- [x] Media card: media type + profile together, hint when the profile name points to another media type
- [x] Inspector as cards with Tabler icons (MIT, App/Resources/TABLER-LICENSE.txt), fixed label column, more spacing

## Open
- [x] First real print over the Wi-Fi queue (Tecco PD190 Duo Matt, A4, 2×2 grid)
- [ ] Test print vs. Professional Print & Layout on the same paper (manual)
- [ ] Gamut warning in softproof
- [ ] Multiple sheets per document, save/open layouts
- [ ] Free cell positioning (drag/resize cells)
- [ ] German localization
- [x] Rename before publishing (trademark): now "Print Lab"
