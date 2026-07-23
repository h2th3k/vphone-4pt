#import "vphoned_tcc.h"
#import "vphoned_protocol.h"
#import <sqlite3.h>
#include <string.h>

static NSString *const kTCCDatabasePath = @"/private/var/mobile/Library/TCC/TCC.db";

static BOOL column_exists(sqlite3 *db, NSString *table, NSString *column) {
  NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", table];
  sqlite3_stmt *stmt = NULL;
  BOOL found = NO;
  if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
    while (sqlite3_step(stmt) == SQLITE_ROW) {
      const unsigned char *name = sqlite3_column_text(stmt, 1);
      if (name && strcmp((const char *)name, column.UTF8String) == 0) {
        found = YES;
        break;
      }
    }
  }
  sqlite3_finalize(stmt);
  return found;
}

static BOOL exec_sql(sqlite3 *db, NSString *sql, NSString **errorOut) {
  char *err = NULL;
  int rc = sqlite3_exec(db, sql.UTF8String, NULL, NULL, &err);
  if (rc != SQLITE_OK) {
    if (errorOut) {
      *errorOut = err ? [NSString stringWithUTF8String:err]
                      : [NSString stringWithFormat:@"sqlite rc=%d", rc];
    }
    if (err)
      sqlite3_free(err);
    return NO;
  }
  return YES;
}

static BOOL grant_service(sqlite3 *db, NSString *service, NSString *bundleID,
                          NSString **errorOut) {
  sqlite3_stmt *deleteStmt = NULL;
  const char *deleteSQL =
      "DELETE FROM access WHERE service = ? AND client = ? AND client_type = 0";
  if (sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, NULL) != SQLITE_OK) {
    if (errorOut)
      *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    return NO;
  }
  sqlite3_bind_text(deleteStmt, 1, service.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(deleteStmt, 2, bundleID.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_step(deleteStmt);
  sqlite3_finalize(deleteStmt);

  NSMutableArray<NSString *> *columns = [@[
    @"service", @"client", @"client_type", @"auth_value", @"auth_reason",
    @"auth_version"
  ] mutableCopy];
  NSMutableArray<NSString *> *values = [@[
    @"?", @"?", @"0", @"2", @"4", @"1"
  ] mutableCopy];

  NSDictionary<NSString *, NSString *> *optionalColumns = @{
    @"csreq" : @"NULL",
    @"policy_id" : @"NULL",
    @"indirect_object_identifier_type" : @"0",
    @"indirect_object_identifier" : @"'UNUSED'",
    @"indirect_object_code_identity" : @"NULL",
    @"flags" : @"0",
    @"last_modified" : @"strftime('%s','now')",
    @"pid" : @"0",
    @"pid_version" : @"0",
    @"boot_uuid" : @"'UNUSED'",
    @"last_reminded" : @"strftime('%s','now')",
  };

  for (NSString *column in optionalColumns) {
    if (column_exists(db, @"access", column)) {
      [columns addObject:column];
      [values addObject:optionalColumns[column]];
    }
  }

  NSString *sql = [NSString
      stringWithFormat:@"INSERT INTO access (%@) VALUES (%@)",
                       [columns componentsJoinedByString:@", "],
                       [values componentsJoinedByString:@", "]];

  sqlite3_stmt *insertStmt = NULL;
  if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &insertStmt, NULL) !=
      SQLITE_OK) {
    if (errorOut)
      *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    return NO;
  }
  sqlite3_bind_text(insertStmt, 1, service.UTF8String, -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(insertStmt, 2, bundleID.UTF8String, -1, SQLITE_TRANSIENT);
  int rc = sqlite3_step(insertStmt);
  if (rc != SQLITE_DONE) {
    if (errorOut)
      *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    sqlite3_finalize(insertStmt);
    return NO;
  }
  sqlite3_finalize(insertStmt);
  return YES;
}

NSDictionary *vp_handle_tcc_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  if (![type isEqualToString:@"tcc_grant_bluetooth"]) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString stringWithFormat:@"unknown TCC command: %@", type];
    return r;
  }

  NSString *bundleID = msg[@"bundle_id"];
  if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"missing bundle_id";
    return r;
  }

  sqlite3 *db = NULL;
  int rc = sqlite3_open_v2(kTCCDatabasePath.UTF8String, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL);
  if (rc != SQLITE_OK) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = [NSString
        stringWithFormat:@"open TCC.db failed: %s", sqlite3_errmsg(db)];
    if (db)
      sqlite3_close(db);
    return r;
  }

  NSString *error = nil;
  BOOL ok = exec_sql(db, @"BEGIN IMMEDIATE", &error);
  if (ok)
    ok = grant_service(db, @"kTCCServiceBluetoothAlways", bundleID, &error);
  if (ok)
    ok = grant_service(db, @"kTCCServiceBluetoothPeripheral", bundleID, &error);
  if (ok)
    ok = exec_sql(db, @"COMMIT", &error);
  else
    exec_sql(db, @"ROLLBACK", NULL);

  sqlite3_close(db);

  NSMutableDictionary *r = vp_make_response(ok ? @"tcc_grant_bluetooth" : @"err", reqId);
  r[@"ok"] = @(ok);
  r[@"bundle_id"] = bundleID;
  if (!ok)
    r[@"msg"] = error ?: @"failed to grant Bluetooth permission";
  else
    r[@"msg"] = @"Bluetooth TCC permission granted; restart the app or SpringBoard.";
  return r;
}
