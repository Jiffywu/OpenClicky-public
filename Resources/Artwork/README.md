# OpenClicky app icon

The [source PNG](AppIcon-source.png) was generated with the built-in ImageGen tool for OpenClicky. The [exact prompt](AppIcon-prompt.txt) requests original artwork and excludes existing assistant logos and HeyClicky artwork. The generated PNG is retained unchanged, including its transparency.

Run `scripts/build-app-icon.sh` from the repository root to regenerate [AppIcon.icns](../App/AppIcon.icns). It uses macOS `sips` to produce the standard 16 through 1024 pixel representations and `iconutil` to package them. The normal app build copies the ICNS into `Contents/Resources` and declares it with `CFBundleIconFile` in `Info.plist`.

The source image and prompt are kept outside `Resources/App` so they are not copied into the app bundle.
