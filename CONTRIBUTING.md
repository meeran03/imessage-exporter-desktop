# Contributing

Small, focused pull requests are welcome. Describe the problem, what changed,
and how you checked it. Open an issue before large changes so we can agree on
the scope.

Use the sample library or invented SQLite fixtures. Do not commit a real chat,
backup, contact list, attachment, export, or screenshot containing personal data.
Build and test instructions are in the README. The engine integration test needs
`MESSAGE_ARCHIVE_TEST_ENGINE` set to the matching local executable and
`MESSAGE_ARCHIVE_TEST_BACKUP_READER` set to the bundled backup-reader helper.

The native UI is in `Sources/MessageArchive/`. Source loading, thread isolation,
and exporting are in `Sources/ArchiveCore/`. Keep original sources read-only,
missing-content reports explicit, and exports usable without this app installed.

Before opening a pull request, run the Swift tests and package the app. For UI
changes, check loading, search, empty results, export progress, cancellation,
and completion using the sample library. Contributions use GPL-3.0-only.
