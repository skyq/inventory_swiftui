import Foundation
import GRDB

/// Схема БД версии 2. SQL v1 повторяет §5 ТЗ и совместим с данными Flutter-версии;
/// v2 добавляет флаг скрытия статуса (`statuses.is_hidden`).
public enum Schema {
  public static let version = 2

  public static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(
        sql: """
          CREATE TABLE places (
            id TEXT PRIMARY KEY,
            parent_id TEXT REFERENCES places(id) ON DELETE RESTRICT,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            photo_file TEXT NOT NULL,
            thumb_file TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          );

          CREATE TABLE statuses (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_archived INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL,
            created_at INTEGER NOT NULL
          );

          CREATE TABLE people (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            phone TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            is_archived INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          );

          CREATE TABLE items (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity >= 1),
            place_id TEXT REFERENCES places(id) ON DELETE RESTRICT,
            status_id TEXT NOT NULL REFERENCES statuses(id) ON DELETE RESTRICT,
            photo_file TEXT NOT NULL,
            thumb_file TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          );

          CREATE TABLE tags (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            name_key TEXT NOT NULL UNIQUE
          );

          CREATE TABLE item_tags (
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (item_id, tag_id)
          );

          CREATE TABLE status_changes (
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
            from_status_id TEXT NOT NULL REFERENCES statuses(id) ON DELETE RESTRICT,
            to_status_id TEXT NOT NULL REFERENCES statuses(id) ON DELETE RESTRICT,
            comment TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
          );

          CREATE TABLE transfers (
            id TEXT PRIMARY KEY,
            item_id TEXT NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
            kind TEXT NOT NULL CHECK (kind IN ('give','return')),
            person_id TEXT NOT NULL REFERENCES people(id) ON DELETE RESTRICT,
            comment TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
          );

          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          );

          CREATE TRIGGER status_changes_no_update BEFORE UPDATE ON status_changes
          BEGIN SELECT RAISE(ABORT, 'history is immutable'); END;

          CREATE TRIGGER status_changes_no_delete BEFORE DELETE ON status_changes
          BEGIN SELECT RAISE(ABORT, 'history is immutable'); END;

          CREATE TRIGGER transfers_no_update BEFORE UPDATE ON transfers
          BEGIN SELECT RAISE(ABORT, 'history is immutable'); END;

          CREATE TRIGGER transfers_no_delete BEFORE DELETE ON transfers
          BEGIN SELECT RAISE(ABORT, 'history is immutable'); END;

          CREATE INDEX items_place_id ON items(place_id);
          CREATE INDEX items_status_id ON items(status_id);
          CREATE INDEX places_parent_id ON places(parent_id);
          CREATE INDEX item_tags_tag_id ON item_tags(tag_id);
          CREATE INDEX status_changes_item_created ON status_changes(item_id, created_at);
          CREATE INDEX transfers_item_created ON transfers(item_id, created_at);
          CREATE INDEX transfers_person_id ON transfers(person_id);
          """)
    }
    migrator.registerMigration("v2") { db in
      try db.execute(
        sql: "ALTER TABLE statuses ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0")
    }
    return migrator
  }
}
