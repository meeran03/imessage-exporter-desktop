import Foundation

/// Entirely invented data for screenshots and repeatable tests. No personal library is read.
public enum DemoLibrary {
    public static func make() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("message-archive-demo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("chat.db")
        let db = try Database(url, writable: true)
        try db.execute("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY,guid TEXT,style INTEGER DEFAULT 45,display_name TEXT,chat_identifier TEXT,service_name TEXT,room_name TEXT)")
        try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY,id TEXT,service TEXT,person_centric_id TEXT)")
        try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER,handle_id INTEGER)")
        try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER,message_id INTEGER,message_date INTEGER)")
        try db.execute("CREATE TABLE chat_lookup (identifier TEXT,domain TEXT,chat INTEGER,priority INTEGER)")
        try db.execute("CREATE TABLE chat_recoverable_message_join (chat_id INTEGER,message_id INTEGER,delete_date INTEGER,ck_sync_state INTEGER)")
        try db.execute("CREATE TABLE recoverable_message_part (chat_id INTEGER,message_id INTEGER,part_index INTEGER,delete_date INTEGER,part_text TEXT,ck_sync_state INTEGER)")
        let textColumns = ["guid", "text", "service", "account", "account_guid", "service_center", "subject", "country", "balloon_bundle_id",
                           "associated_message_guid", "expressive_send_style_id", "thread_originator_guid", "thread_originator_part", "associated_message_emoji",
                           "reply_to_guid", "destination_caller_id", "group_title", "ck_record_id", "ck_chat_id"]
        let intColumns = ["date", "date_read", "date_delivered", "is_from_me", "handle_id", "other_handle", "version", "type", "error",
                          "is_delivered", "is_finished", "is_emote", "is_empty", "is_delayed", "is_auto_reply", "is_prepared", "is_read",
                          "is_system_message", "is_sent", "has_dd_results", "is_service_message", "is_forward", "was_downgraded", "is_archive",
                          "cache_has_attachments", "was_data_detected", "was_deduplicated", "is_audio_message", "is_played", "date_played", "item_type",
                          "group_action_type", "share_status", "share_direction", "is_expirable", "expire_state", "message_action_type", "message_source",
                          "associated_message_type", "associated_message_range_location", "associated_message_range_length", "time_expressive_send_played",
                          "ck_sync_state", "is_corrupt", "sort_id", "is_spam", "has_unseen_mention", "was_delivered_quietly", "did_notify_recipient",
                          "date_retracted", "date_edited", "was_detonated", "part_count", "is_stewie", "is_sos", "is_critical", "bia_reference_id",
                          "is_kt_verified", "is_pending_satellite_send", "needs_relay", "schedule_type", "schedule_state", "sent_or_received_off_grid",
                          "date_recovered", "is_time_sensitive", "index_state"]
        let blobColumns = ["attributedBody", "payload_data", "message_summary_info", "cache_roomnames", "ck_record_change_tag", "syndication_ranges", "synced_syndication_ranges", "fallback_hash"]
        let definitions = textColumns.map { quote($0) + " TEXT" } + intColumns.map { quote($0) + " INTEGER DEFAULT 0" } + blobColumns.map { quote($0) + " BLOB" }
        try db.execute("CREATE TABLE message (ROWID INTEGER PRIMARY KEY," + definitions.joined(separator: ",") + ")")
        try db.execute("CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY,guid TEXT,filename TEXT,transfer_name TEXT,mime_type TEXT,total_bytes INTEGER,uti TEXT,is_sticker INTEGER DEFAULT 0,is_outgoing INTEGER DEFAULT 0,transfer_state INTEGER DEFAULT 5,user_info BLOB,sticker_user_info BLOB,attribution_info BLOB,hide_attachment INTEGER DEFAULT 0,created_date INTEGER,start_date INTEGER,original_guid TEXT,emoji_image_content_identifier TEXT,emoji_image_short_description TEXT,preview_generation_state INTEGER DEFAULT 0)")
        try db.execute("CREATE TABLE message_attachment_join (message_id INTEGER,attachment_id INTEGER)")
        let people = ["Avery Example", "Weekend plans", "Sam Sample", "Book club"]
        let identifiers = ["+15550001001", "sample-weekend-group", "sam@example.invalid", "sample-book-club"]
        for index in people.indices {
            let id = Int64(index + 1)
            try db.execute("INSERT INTO chat (ROWID,guid,display_name,chat_identifier,service_name) VALUES (?,?,?,?,?)",
                           [.integer(id), .text("iMessage;-;" + identifiers[index]), .text(people[index]), .text(identifiers[index]), .text("iMessage")])
            try db.execute("INSERT INTO handle (ROWID,id,service) VALUES (?,?,?)", [.integer(id), .text(identifiers[index]), .text("iMessage")])
            try db.execute("INSERT INTO chat_handle_join VALUES (?,?)", [.integer(id), .integer(id)])
            if index == 1 || index == 3 { try db.execute("INSERT INTO chat_handle_join VALUES (?,?)", [.integer(id), .integer(1)]) }
        }
        let examples = ["Want to grab coffee this weekend?", "Saturday works for me!", "Here's the itinerary I mentioned.", "Perfect, see you then 🌿"]
        var messageID: Int64 = 0
        for chatID in 1...4 {
            for index in 0..<8 {
                messageID += 1
                let time = Int64(790_000_000_000_000_000) + Int64(chatID * 86_400 + index * 3_600) * 1_000_000_000
                try db.execute("INSERT INTO message (ROWID,guid,text,date,is_from_me,handle_id,service,is_read,is_sent,is_finished) VALUES (?,?,?,?,?,?,?,?,?,?)",
                               [.integer(messageID), .text("synthetic-\(messageID)"), .text(examples[index % examples.count]), .integer(time),
                                .integer(Int64(index % 2)), .integer(Int64(chatID)), .text("iMessage"), .integer(1), .integer(1), .integer(1)])
                try db.execute("INSERT INTO chat_message_join VALUES (?,?,?)", [.integer(Int64(chatID)), .integer(messageID), .integer(time)])
            }
        }
        let attachment = root.appendingPathComponent("Itinerary.txt")
        try "Sample itinerary\nSaturday: coffee at 10, then a walk.\nEntirely synthetic demo data.\n".write(to: attachment, atomically: true, encoding: .utf8)
        try db.execute("INSERT INTO attachment (ROWID,guid,filename,transfer_name,mime_type,total_bytes) VALUES (1,'synthetic-attachment',?,'Itinerary.txt','text/plain',?)",
                       [.text(attachment.path), .integer(Int64(try Data(contentsOf: attachment).count))])
        try db.execute("INSERT INTO message_attachment_join VALUES (3,1)")
        try db.execute("UPDATE message SET cache_has_attachments=1 WHERE ROWID=3")
        return url
    }
}
