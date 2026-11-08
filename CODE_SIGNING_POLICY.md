# Code signing policy

Free code signing for the Windows installer (`DubbingSystem_Setup.exe`) is provided by [SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org).

Бесплатная подпись Windows-установщика (`DubbingSystem_Setup.exe`) предоставляется [SignPath.io](https://signpath.io), сертификат выдан [SignPath Foundation](https://signpath.org).

## Team roles / Роли

| Role | Member |
|------|--------|
| Authors / Committers and Reviewers | [zaraki999kenpachi](https://github.com/zaraki999kenpachi) |
| Approvers | [zaraki999kenpachi](https://github.com/zaraki999kenpachi) |

All team members use multi-factor authentication on GitHub.

## What is signed / Что подписывается

Only binaries built from this repository's source by the project's own build, and released at
https://github.com/zaraki999kenpachi/DubbingSystem/releases:

- `DubbingSystem_Setup.exe` (Windows installer, Inno Setup).

Every release is signed only after a manual approval by an Approver.
The installer bundles unmodified upstream REAPER extensions (ReaImGui, ReaPack, js_ReaScriptAPI)
under their own open source licenses; they are not modified by this project.

## Privacy policy / Конфиденциальность

This program does not transfer any information to other networked systems unless specifically
requested by the user or the person installing or operating it.
(The installer itself works offline; it does not collect or send any data.)

Программа не передаёт никакой информации в сторонние сети, если этого явно не запросил
пользователь. Установщик работает офлайн и ничего не собирает и не отправляет.

## What the installer changes / Что меняет установщик

Copies scripts, fonts and (optionally) REAPER extensions into the chosen REAPER resource folder,
optionally adds one marked line to `Scripts/__startup.lua`, and registers an uninstaller.
Everything it installs is removed by the uninstaller.
