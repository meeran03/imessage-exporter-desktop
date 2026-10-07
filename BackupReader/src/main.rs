use crabapple::{Authentication, Backup};
use std::{fs, io::{self, Read, Write}, path::Path, os::unix::fs::PermissionsExt};

fn main() {
    if run().is_err() {
        // Never print credentials or arbitrary backup metadata in error messages.
        eprintln!("Could not unlock or read this backup. Check the password and backup integrity.");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 { return Err("Expected source and temporary destination".into()); }
    let source = Path::new(&args[1]);
    let destination = Path::new(&args[2]);
    if destination.exists() { return Err("Working destination already exists".into()); }
    let mut password = String::new();
    io::stdin().take(16_384).read_to_string(&mut password)?;
    let backup = Backup::open(source, &Authentication::Password(password))?;
    fs::create_dir(destination)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o700))?;
    fs::copy(backup.manifest_db_path(), destination.join("Manifest.db"))?;
    let mut manifest = plist::Value::from_file(source.join("Manifest.plist"))?;
    let dict = manifest.as_dictionary_mut().ok_or("Invalid manifest")?;
    dict.insert("IsEncrypted".into(), plist::Value::Boolean(false));
    dict.remove("BackupKeyBag"); dict.remove("ManifestKey");
    manifest.to_file_binary(destination.join("Manifest.plist"))?;
    for name in ["Info.plist", "Status.plist"] {
        fs::copy(source.join(name), destination.join(name))?;
    }
    let database = rusqlite::Connection::open_with_flags(backup.manifest_db_path(), rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut query = database.prepare("SELECT fileID,relativePath FROM Files WHERE flags=1 AND ((domain='HomeDomain' AND relativePath='Library/SMS/sms.db') OR (domain='HomeDomain' AND relativePath LIKE 'Library/AddressBook/%') OR (domain IN ('HomeDomain','MediaDomain') AND (relativePath LIKE 'Library/SMS/Attachments/%' OR relativePath LIKE 'Media/Library/SMS/Attachments/%' OR relativePath LIKE 'Library/SMS/StickerCache/%')))")?;
    let rows = query.query_map([], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?;
    for row in rows {
        let (id,path) = row?;
        if id.len()!=40 || !id.bytes().all(|b| b.is_ascii_hexdigit()) { return Err("Invalid file identifier".into()); }
        let result = (|| -> Result<(),Box<dyn std::error::Error>> {
            let entry = backup.get_file(&id)?;
            let folder = destination.join(&id[..2]); fs::create_dir_all(&folder)?;
            let target = folder.join(&id);
            if backup.is_encrypted() {
                let mut reader = backup.decrypt_entry_stream(&entry)?;
                let mut file = fs::File::create(&target)?;
                let written = io::copy(&mut reader, &mut file)?;
                if written < entry.metadata.size { return Err("Incomplete decrypted file".into()); }
                file.set_len(entry.metadata.size)?;
            } else {
                fs::copy(source.join(entry.source()), &target)?;
            }
            fs::set_permissions(&target,fs::Permissions::from_mode(0o600))?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(destination.join(&id[..2]).join(&id));
            if path=="Library/SMS/sms.db" { return Err("Messages database could not be decrypted".into()); }
        }
        // Missing individual attachments remain missing, and the export report describes them.
        println!("Reading Messages files..."); io::stdout().flush()?;
    }
    Ok(())
}
