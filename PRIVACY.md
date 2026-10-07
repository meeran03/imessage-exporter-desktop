# Privacy

iMessage Exporter processes your selected source on your Mac. It has no account
system, analytics, crash uploader, web API, or background sync. Contact-name
lookup uses macOS Contacts with your permission. iPhone backup contacts are read
from the local backup itself.

The app opens original databases read-only. A private temporary folder holds a
filtered copy while exporting, and that folder is removed at the end of the
operation. A sudden crash or forced shutdown may leave a temporary folder in
the system's temporary directory. Exports and ZIPs stay where you chose to save
them until you delete them. Their transcripts and logs contain private data.

When you choose **Connect iPhone**, the app creates a full local device backup,
including data beyond Messages. It is saved in the folder you choose and remains
there until you delete it. Backups can take significant disk space. A cancelled
or failed backup remains in that folder, clearly marked as not loaded. Nothing
is uploaded. The app preserves existing backup encryption settings and does not
restore the phone, delete contacts, or edit messages.

For encrypted backups, the password travels to a bundled reader through a pipe,
not command arguments, environment variables, or saved logs. It is not saved for
future sessions. Decrypted Messages, backup contact records, and Messages
attachments are kept in a private temporary folder while that source is open.
That working folder is removed when switching sources or quitting normally.
A crash or forced shutdown may leave a working folder in the system's temporary
directory. The full encrypted backup remains in the chosen location.

The app's processing does not require a network connection. Opening the project
link, Apple help, or external links within exported conversations uses your
browser and can contact those sites. Sharing an export is your choice.

Issue reports should contain only a description, app/macOS versions, and
synthetic examples. Redact personal information before sharing logs.
