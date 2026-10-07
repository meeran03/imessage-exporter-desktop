# Third-party software

iMessage Exporter bundles unmodified official imessage-exporter 4.3.0 executables
for Apple Silicon and Intel, combined into a universal executable with Apple's
lipo tool. imessage-exporter is developed by ReagentX and its contributors and
licensed under GNU GPL version 3.

Upstream project: https://github.com/ReagentX/imessage-exporter
Pinned source: https://github.com/ReagentX/imessage-exporter/tree/4.3.0
License: https://github.com/ReagentX/imessage-exporter/blob/4.3.0/LICENSE

Each public binary release is accompanied by a source archive. The archive
includes iMessage Exporter's source and build scripts, the pinned upstream
source, Cargo.lock, and vendored source for its dependencies with their own
license notices. The entire app is distributed under GPL-3.0-only. There is no
warranty. Users may redistribute and modify it under the license's terms.

The app links Apple's system frameworks and system SQLite. Those system
components are not redistributed as part of the application.

## iPhone backup tools

The app bundles universal builds of libimobiledevice 1.4.0 command-line tools,
libimobiledevice-glue 1.3.3, libusbmuxd 2.1.1, libplist 2.8.0, and OpenSSL 3.6.5.
The build also uses libtatsu 1.0.5 and libtasn1 4.21.0. Exact source URLs, SHA-256
checksums, and license identifiers are in iphone-sources.json. Full source
archives and build scripts accompany each release. License notices are included
inside the app under Contents/Resources/iphone/licenses/.

The bundled libimobiledevice tools and libraries, libimobiledevice-glue,
libplist, libtatsu, and libtasn1 use LGPL-2.1-or-later. libusbmuxd includes
GPL-2.0-or-later and LGPL-2.1-or-later components. OpenSSL uses Apache-2.0.
Libraries are dynamically linked, and corresponding source and build scripts
allow modified builds. None of these projects is affiliated with Apple.

The GPL-3.0-only backup-reader helper uses crabapple 0.4.7 (MIT), plist, rusqlite,
and their locked dependencies. Their source and license notices are vendored in
the accompanying source archive. Dependency license texts are also bundled under
Contents/Resources/Rust-Licenses/. The helper decrypts only Messages, backup
contacts, and Messages attachments into the session's private working folder.
