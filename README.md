# Pitch Canvas Extension — Adaptive Precision

Adaptive pitch control for VST3 instruments in REAPER.

Helps VST3 instruments follow Pitch Canvas curves more closely while keeping them in your regular REAPER FX chain. Compare Off and Adaptive on a short passage, listen to the result, and save your choice.

This is an experimental REAPER extension. Pitch Canvas and your instruments are installed separately.

## Install

1. Install [ReaPack](https://reapack.com/) and restart REAPER.
2. Choose **Extensions → ReaPack → Import repositories** and paste:

   `https://raw.githubusercontent.com/PontakuAudio/PitchCanvas-Extension-Adaptive-Precision/main/index.xml`

3. In **Browse packages**, search **Adaptive Precision**, select the row, then choose **Actions → Install v0.11.0-pre2** (or a newer version) and **Apply**.
4. **Restart REAPER**. In Actions, run **Pitch Canvas Extension — Adaptive Precision**.
5. Put Pitch Canvas and a supported VST3 instrument on the same track. Turn precision **On**, or select an instrument and use **Compare** before deciding. Save the project to retain the applied settings.

Update through ReaPack and restart REAPER. To remove, uninstall the package through ReaPack and restart. Project settings and shared comparison results remain available if you reinstall. Do not install manual updates over a ReaPack-managed installation.

macOS Intel/Apple Silicon and Windows x64 are supported. macOS Apple Silicon has been tested in REAPER; Windows and Intel build checks do not constitute an instrument compatibility guarantee. Linux, 32-bit REAPER, AU/CLAP instruments, bridged instruments, take/input FX and FX containers are not supported. Some incompatible instruments are excluded automatically. This extension uses experimental interception of VST3 processing; CPU use and sound may change. It starts Off in new projects. **Compare** measures a short passage on the existing instrument without creating a project, track or audio file.

For old manual installations, REAPER must be restarted after migration. The old `Scripts/PitchCanvas` copies are no longer used by the extension action; remove any manually registered old script action if necessary. Use the extension's **Adaptive Precision** action above.

The package owns only its extension binary, panel/helper scripts, documentation and licenses under `UserPlugins`. It does not install or modify the PitchCanvas plug-in, instrument plug-ins, projects or shared comparison records.

## License

Copyright Pontaku Audio. The existing PitchCanvas EULA applies; see the bundled `PitchCanvasPrecisionLicenses/EULA_en.txt` / `EULA_ja.txt`. This distribution repository is not an open-source license for PitchCanvas. Third-party notices for fishhook, the REAPER SDK excerpts and the VST3 SDK are included in the same directory. REAPER, ReaPack and instrument plug-ins are not bundled.
