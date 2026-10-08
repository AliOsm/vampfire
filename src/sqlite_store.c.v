module main

import db.sqlite
import os
import sync

// The upstream convenience API prepares and finalizes on every call. Keep the
// statement lifetime here, beside the application's connection ownership.
fn C.sqlite3_open_v2(&char, &&C.sqlite3, int, &char) int
fn C.sqlite3_close(&C.sqlite3) int
fn C.sqlite3_prepare_v2(&C.sqlite3, &char, int, &&C.sqlite3_stmt, &&char) int
fn C.sqlite3_step(&C.sqlite3_stmt) int
fn C.sqlite3_reset(&C.sqlite3_stmt) int
fn C.sqlite3_clear_bindings(&C.sqlite3_stmt) int
fn C.sqlite3_finalize(&C.sqlite3_stmt) int
fn C.sqlite3_bind_text(&C.sqlite3_stmt, int, &char, int, voidptr) int
fn C.sqlite3_column_count(&C.sqlite3_stmt) int
fn C.sqlite3_column_name(&C.sqlite3_stmt, int) &char
fn C.sqlite3_column_text(&C.sqlite3_stmt, int) &u8
fn C.sqlite3_column_bytes(&C.sqlite3_stmt, int) int
fn C.sqlite3_errmsg(&C.sqlite3) &char
fn C.sqlite3_busy_timeout(&C.sqlite3, int) int
fn C.sqlite3_last_insert_rowid(&C.sqlite3) i64
fn C.sqlite3_wal_hook(&C.sqlite3, fn (voidptr, &C.sqlite3, &char, int) int, voidptr) voidptr
fn C.sqlite3_wal_checkpoint_v2(&C.sqlite3, &char, int, &int, &int) int

@[heap]
struct PreparedQuery {
	stmt  &C.sqlite3_stmt
	names []string
}

@[heap]
struct SqlConnection {
	handle &C.sqlite3
mut:
	queries map[string]&PreparedQuery
	keys    []string
	next    int
	pages   int
}

@[heap]
struct DatabasePool {
	readers     chan &SqlConnection
	writer      chan &SqlConnection
	checkpoints chan bool
	checkpoint  &SqlConnection
	observer    &SqlConnection
mut:
	checkpoint_mu sync.Mutex
	observer_mu   sync.Mutex
	data_version  i64
	generation    u64
}

// A lightweight request/job session. Outside a transaction, SQL leases a
// connection only for that query. Session objects are never shared by callers.
@[heap]
struct Database {
	pool &DatabasePool
mut:
	transaction &SqlConnection = unsafe { nil }
	last_id     i64
}

fn open_database(directory string) !&Database {
	os.mkdir_all(directory)!
	path := os.join_path(directory, 'vampfire.sqlite3')
	mut writer := connect_sqlite(path, false)!
	pool := &DatabasePool{
		readers:     chan &SqlConnection{cap: 4}
		writer:      chan &SqlConnection{cap: 1}
		checkpoints: chan bool{cap: 1}
		checkpoint:  connect_sqlite(path, false)!
		observer:    connect_sqlite(path, true)!
	}
	for _ in 0 .. 4 { pool.readers <- connect_sqlite(path, true)! }
	C.sqlite3_wal_hook(writer.handle, record_wal_size, writer)
	pool.writer <- writer
	spawn checkpoint_worker(pool)
	return &Database{ pool: pool }
}

fn connect_sqlite(path string, reader bool) !&SqlConnection {
	mut handle := &C.sqlite3(unsafe { nil })
	// READWRITE | CREATE | NOMUTEX: each connection has one owner at a time.
	if C.sqlite3_open_v2(&char(path.str), &handle, 2 | 4 | 0x8000, unsafe { nil }) != 0 {
		if handle != unsafe { nil } { C.sqlite3_close(handle) }
		return error('Could not open database.')
	}
	mut conn := &SqlConnection{ handle: handle }
	C.sqlite3_busy_timeout(handle, 5000)
	for pragma in ['journal_mode=WAL', 'foreign_keys=ON', 'synchronous=NORMAL', 'cache_size=-4096',
		'mmap_size=0', 'wal_autocheckpoint=0'] {
		conn.run('PRAGMA ' + pragma, [])!
	}
	if reader { conn.run('PRAGMA query_only=ON', [])! }
	return conn
}

fn (db &Database) session() &Database { return &Database{ pool: db.pool } }

fn (db &Database) close() ! {
	db.pool.checkpoints.close()
	// close() is used only after all application work has stopped (unit tests).
	mut writer := <-db.pool.writer
	writer.close()
	for _ in 0 .. 4 {
		mut reader := <-db.pool.readers
		reader.close()
	}
	mut pool := db.pool
	pool.observer_mu.lock()
	mut observer := pool.observer
	observer.close()
	pool.observer_mu.unlock()
}

fn (mut conn SqlConnection) close() {
	for _, prepared in conn.queries { C.sqlite3_finalize(prepared.stmt) }
	conn.queries.clear()
	C.sqlite3_close(conn.handle)
}

fn (mut conn SqlConnection) run(statement string, values []string) ![]sqlite.Row {
	prepared := if cached := conn.queries[statement] {
		cached
	} else {
		mut stmt := &C.sqlite3_stmt(unsafe { nil })
		if C.sqlite3_prepare_v2(conn.handle, &char(statement.str), statement.len, &stmt, unsafe { nil }) != 0 {
			return conn.failure()
		}
		mut names := []string{cap: C.sqlite3_column_count(stmt)}
		for i in 0 .. C.sqlite3_column_count(stmt) {
			names << unsafe { cstring_to_vstring(C.sqlite3_column_name(stmt, i)) }
		}
		entry := &PreparedQuery{ stmt: stmt, names: names }
		if statement.len <= 8192 {
			if conn.keys.len == 256 {
				old := conn.keys[conn.next]
				if previous := conn.queries[old] { C.sqlite3_finalize(previous.stmt) }
				conn.queries.delete(old)
				conn.keys[conn.next] = statement
				conn.next = (conn.next + 1) % 256
			} else {
				conn.keys << statement
			}
			conn.queries[statement] = entry
		}
		entry
	}
	defer {
		C.sqlite3_reset(prepared.stmt)
		C.sqlite3_clear_bindings(prepared.stmt)
		if statement.len > 8192 { C.sqlite3_finalize(prepared.stmt) }
	}
	for i, value in values {
		// Bound strings remain alive until reset below; SQLite need not copy them.
		if C.sqlite3_bind_text(prepared.stmt, i + 1, &char(value.str), value.len, unsafe { nil }) != 0 {
			return conn.failure()
		}
	}
	mut rows := []sqlite.Row{}
	for {
		code := C.sqlite3_step(prepared.stmt)
		if code == 101 { break }
		if code != 100 { return conn.failure() }
		mut vals := []string{cap: prepared.names.len}
		for i in 0 .. prepared.names.len {
			ptr := C.sqlite3_column_text(prepared.stmt, i)
			len := C.sqlite3_column_bytes(prepared.stmt, i)
			vals << if ptr == unsafe { nil } {
				''
			} else {
				unsafe { ptr.vstring_with_len(len).clone() }
			}
		}
		rows << sqlite.Row{ names: prepared.names, vals: vals }
	}
	return rows
}

fn (conn &SqlConnection) failure() IError {
	return error(unsafe { cstring_to_vstring(C.sqlite3_errmsg(conn.handle)) })
}

fn query(db &Database, statement string, values ...string) ![]sqlite.Row {
	mut session := unsafe { &Database(db) }
	if session.transaction != unsafe { nil } {
		mut conn := session.transaction
		rows := conn.run(statement, values)!
		session.last_id = C.sqlite3_last_insert_rowid(conn.handle)
		return rows
	}
	readonly := statement.starts_with('SELECT ') || statement.starts_with('EXPLAIN ')
		|| statement == 'PRAGMA user_version'
	mut conn := if readonly { <-db.pool.readers } else { <-db.pool.writer }
	defer {
		if readonly {
			db.pool.readers <- conn
		} else {
			db.pool.finish_write(mut conn)
			db.pool.writer <- conn
		}
	}
	rows := conn.run(statement, values)!
	if !readonly { session.last_id = C.sqlite3_last_insert_rowid(conn.handle) }
	return rows
}

fn (db &Database) exec(statement string) ![]sqlite.Row {
	mut session := unsafe { &Database(db) }
	command := statement.trim_space()
	if command == 'BEGIN IMMEDIATE' {
		if session.transaction != unsafe { nil } { return error('Nested transaction.') }
		mut conn := <-db.pool.writer
		conn.run(command, []) or {
			db.pool.writer <- conn
			return err
		}
		session.transaction = conn
		return []sqlite.Row{}
	}
	if command in ['COMMIT', 'ROLLBACK'] {
		if session.transaction == unsafe { nil } { return []sqlite.Row{} }
		mut conn := session.transaction
		rows := conn.run(command, [])!
		session.transaction = unsafe { nil }
		db.pool.finish_write(mut conn)
		db.pool.writer <- conn
		return rows
	}
	return query(db, statement)
}

fn (db &Database) q_int(statement string) !int { return query(db, statement)![0].vals[0].int() }

fn (db &Database) last_insert_rowid() i64 { return db.last_id }

fn record_wal_size(ref voidptr, _handle &C.sqlite3, _name &char, pages int) int {
	mut conn := unsafe { &SqlConnection(ref) }
	conn.pages = pages
	return 0
}

fn (pool &DatabasePool) finish_write(mut conn SqlConnection) {
	if conn.pages >= 10000 {
		mut shared_pool := unsafe { &DatabasePool(pool) }
		shared_pool.checkpoint_mu.lock()
		C.sqlite3_wal_checkpoint_v2(conn.handle, unsafe { nil }, 2, unsafe { nil }, unsafe { nil })
		shared_pool.checkpoint_mu.unlock()
	} else if conn.pages >= 1000 {
		select {
			pool.checkpoints <- true {
			}
			else {
			}
		}
	}
}

fn checkpoint_worker(pool &DatabasePool) {
	for {
		_ := <-pool.checkpoints or { break }
		mut shared_pool := unsafe { &DatabasePool(pool) }
		shared_pool.checkpoint_mu.lock()
		C.sqlite3_wal_checkpoint_v2(pool.checkpoint.handle, unsafe { nil }, 0, unsafe { nil }, unsafe { nil })
		shared_pool.checkpoint_mu.unlock()
	}
	mut conn := pool.checkpoint
	conn.close()
}

// Observe every connection's commits, including direct writes by maintenance
// tools. Call before authentication and after rendering when admitting a cache entry.
fn (db &Database) generation() !u64 {
	mut pool := db.pool
	pool.observer_mu.lock()
	defer { pool.observer_mu.unlock() }
	mut observer := pool.observer
	version := observer.run('PRAGMA data_version', [])![0].vals[0].i64()
	if version != pool.data_version {
		pool.data_version = version
		pool.generation++
	}
	return pool.generation
}
