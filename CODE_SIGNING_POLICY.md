# Code signing policy

The Windows installer (`DubbingSystem_Setup.exe`) is signed with the author's own code signing certificate (publisher: Kenpachi Zaraki). The certificate is self-issued, so Windows does not publicly trust it and SmartScreen may show a warning ("More info" → "Run anyway"). A publicly trusted signature may be added in the future.

Windows-установщик (`DubbingSystem_Setup.exe`) подписан личным сертификатом автора (издатель: Kenpachi Zaraki). Сертификат самоподписанный, поэтому Windows не доверяет ему публично и SmartScreen может показать предупреждение («Подробнее» → «Выполнить в любом случае»).

## Team / Команда

| Role | Member |
|------|--------|
| Author, reviewer, release signer | [zaraki999kenpachi](https://github.com/zaraki999kenpachi) |

## What is signed / Что подписывается

Only `DubbingSystem_Setup.exe` from the official releases at
https://github.com/zaraki999kenpachi/DubbingSystem/releases.
Every release is signed manually by the author. Check the file with `SHA256SUMS.txt` from the same release.
The installer bundles unmodified upstream REAPER extensions (ReaImGui, ReaPack, js_ReaScriptAPI) under their own open source licenses.

## Privacy / Конфиденциальность

This program does not transfer any information to other networked systems unless specifically requested by the user. The installer works offline and does not collect or send any data.

Программа не передаёт информацию в сторонние сети, если этого явно не запросил пользователь. Установщик работает офлайн и ничего не собирает.

## What the installer changes / Что меняет установщик

Copies scripts, fonts and (optionally) REAPER extensions into the chosen REAPER resource folder, optionally adds one marked line to `Scripts/__startup.lua`, and registers an uninstaller. Everything it installs is removed by the uninstaller.
