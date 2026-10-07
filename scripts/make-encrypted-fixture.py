#!/usr/bin/env python3
"""Build an invented encrypted backup for tests; never accepts phone backups."""
import hashlib
import plistlib
import sqlite3
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

PASSWORD = b'synthetic-fixture-password'

def cipher(data, key, wrap=False):
    if wrap:
        # RFC 3394 using the system AES primitive; macOS LibreSSL's wrap CLI
        # lists the cipher but does not implement enc for it.
        a, blocks = b'\xa6'*8, [data[i:i+8] for i in range(0,len(data),8)]
        for j in range(6):
            for i in range(len(blocks)):
                encrypted = subprocess.run(['/usr/bin/openssl','enc','-aes-256-ecb','-K',key.hex(),'-nopad'],
                    input=a+blocks[i],stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
                a = (int.from_bytes(encrypted[:8],'big') ^ (len(blocks)*j+i+1)).to_bytes(8,'big')
                blocks[i] = encrypted[8:]
        return a+b''.join(blocks)
    return subprocess.run(['/usr/bin/openssl','enc','-aes-256-cbc','-K',key.hex(),'-iv','00'*16],
        input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout

def main():
    demo, output = map(Path, sys.argv[1:])
    output.mkdir(mode=0o700)
    dpsl, salt = b'invented-dpsl', b'invented-salt'
    derived = hashlib.pbkdf2_hmac('sha256', PASSWORD, dpsl, 1024, 32)
    master = hashlib.pbkdf2_hmac('sha1', derived, salt, 1024, 32)
    class_key, file_key = bytes(range(32)), bytes(range(32, 64))
    wrapped = cipher(file_key, class_key, True)
    def tlv(tag, value):
        if isinstance(value, int):
            value = struct.pack('>I', value)
        return tag.encode() + struct.pack('>I', len(value)) + value
    keybag = b''.join(tlv(*pair) for pair in [
        ('TYPE',1), ('UUID',b'0'*16), ('WRAP',2), ('DPSL',dpsl), ('SALT',salt),
        ('DPIC',1024), ('ITER',1024), ('UUID',b'1'*16), ('CLAS',1), ('WRAP',2),
        ('WPKY',cipher(class_key, master, True))])
    with tempfile.TemporaryDirectory(prefix='synthetic-encryption-') as folder:
        work = Path(folder)
        sms = work / 'sms.db'
        # SQLite backup includes WAL state without changing the source demo.
        with sqlite3.connect(demo / 'chat.db') as original, sqlite3.connect(sms) as copy:
            original.backup(copy)
            copy.execute("UPDATE attachment SET filename='~/Library/SMS/Attachments/demo/Itinerary.txt'")
        contacts = work / 'contacts.db'
        with sqlite3.connect(contacts) as db:
            db.executescript("CREATE TABLE ABPerson(ROWID INTEGER PRIMARY KEY,First TEXT,Last TEXT,Organization TEXT); CREATE TABLE ABMultiValue(record_id INTEGER,property INTEGER,value TEXT); INSERT INTO ABPerson VALUES(1,'Avery','Example',NULL); INSERT INTO ABMultiValue VALUES(1,3,'+15550001001');")
        manifest_path = work / 'Manifest.db'
        with sqlite3.connect(manifest_path) as db:
            db.execute('CREATE TABLE Files(fileID TEXT,domain TEXT,relativePath TEXT,flags INTEGER,file BLOB)')
            for domain, path, data in [
                ('HomeDomain','Library/SMS/sms.db',sms.read_bytes()),
                ('HomeDomain','Library/AddressBook/AddressBook.sqlitedb',contacts.read_bytes()),
                ('MediaDomain','Library/SMS/Attachments/demo/Itinerary.txt',(demo/'Itinerary.txt').read_bytes())]:
                file_id = hashlib.sha1((domain+'-'+path).encode()).hexdigest()
                directory = output / file_id[:2]
                directory.mkdir(exist_ok=True, mode=0o700)
                (directory/file_id).write_bytes(cipher(data,file_key))
                metadata = {key:0 for key in ['LastModified','Flags','GroupID','LastStatusChange','Birth','Mode','InodeNumber']}
                metadata.update(Size=len(data), ProtectionClass=1, EncryptionKey=plistlib.UID(2))
                archive = {'$top':{'root':plistlib.UID(1)}, '$objects':['$null',metadata,{'NS.data':struct.pack('<I',1)+wrapped}], '$archiver':'NSKeyedArchiver','$version':100000}
                db.execute('INSERT INTO Files VALUES(?,?,?,1,?)',(file_id,domain,path,plistlib.dumps(archive,fmt=plistlib.FMT_BINARY)))
        (output/'Manifest.db').write_bytes(cipher(manifest_path.read_bytes(),file_key))
    manifest = {'IsEncrypted':True,'BackupKeyBag':keybag,'ManifestKey':struct.pack('<I',1)+wrapped,'Applications':{},
                'Lockdown':{'BuildVersion':'22A000','DeviceName':'Synthetic iPhone','ProductType':'iPhone15,2','ProductVersion':'18.0','SerialNumber':'SYNTHETIC','UniqueDeviceID':'synthetic-test-device'}}
    for name, data in [('Manifest.plist',manifest),('Status.plist',{'SnapshotState':'finished'}),('Info.plist',{'Device Name':'Synthetic iPhone'})]:
        (output/name).write_bytes(plistlib.dumps(data,fmt=plistlib.FMT_BINARY))

if __name__ == '__main__':
    main()
