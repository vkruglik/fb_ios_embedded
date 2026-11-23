# fb_ios_embedded example

A device test of the embedded engine. Each button runs one check and writes
the result to the screen and to `Documents/fbprobe.log` (visible in the
Files app). Run on a device, not the simulator:

```bash
flutter run -d <device id>
flutter run -d <device id> --release   # without the cable
```

Set your own Team in Xcode (Runner → Signing & Capabilities) before the
first run.
