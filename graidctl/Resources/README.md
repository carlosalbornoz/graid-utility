# Resources

Two pictures are G-Technology's artwork, so they aren't in this repository:

- **Img_Device_GRAID.png**, the enclosure picture, from G-Technology's public icon pack. Western
  Digital publishes it in [How to change drive icons on macOS for SanDisk Professional and
  G-Technology](https://support-en.wd.com/app/answers/detailweb/a_id/30548)
  ([direct link to the zip](https://downloads.wdc.com/gtech/icons/G-Technology_Icons.zip)).
- **AppIcon.icns**, the app icon, made from the G logo in the original 2017 Configurator
  (`Img_GR_Icon.png`), fitted onto the macOS icon grid by `tools/make-appicon.swift`.

Add them with:

```sh
tools/fetch-artwork.sh <G-Technology_Icons folder or .zip> ["/path/to/G-RAID with Thunderbolt Configurator.app"]
```

The Configurator argument is optional and only gives the app icon. Without these files the app
builds and runs normally: it shows the system drive symbol and the default app icon. Every
other icon in the app is a system symbol.
