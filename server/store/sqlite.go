package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"termsync-server/models"

	_ "modernc.org/sqlite"
)

// Store handles all database operations
type Store struct {
	db *sql.DB
}

// New creates a new Store with SQLite backend
func New(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	// Optimize SQLite for concurrent access
	optimizations := []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA synchronous=NORMAL",
		"PRAGMA cache_size=-2000",
		"PRAGMA mmap_size=67108864",
		"PRAGMA foreign_keys=ON",
	}

	for _, opt := range optimizations {
		if _, err := db.Exec(opt); err != nil {
			return nil, fmt.Errorf("failed to execute pragma: %w", err)
		}
	}

	store := &Store{db: db}
	if err := store.initSchema(); err != nil {
		return nil, fmt.Errorf("failed to initialize schema: %w", err)
	}

	return store, nil
}

// initSchema creates the database tables if they don't exist
func (s *Store) initSchema() error {
	schema := `
	CREATE TABLE IF NOT EXISTS devices (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		token TEXT UNIQUE NOT NULL,
		type TEXT NOT NULL DEFAULT 'desktop',
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE TABLE IF NOT EXISTS sessions (
		id TEXT PRIMARY KEY,
		device_id TEXT NOT NULL,
		title TEXT,
		layout TEXT,
		status TEXT DEFAULT 'active',
		cols INTEGER DEFAULT 80,
		rows INTEGER DEFAULT 24,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (device_id) REFERENCES devices(id)
	);

	CREATE TABLE IF NOT EXISTS online_status (
		device_id TEXT PRIMARY KEY,
		connected_at DATETIME,
		last_seen DATETIME
	);

	CREATE TABLE IF NOT EXISTS pairing_codes (
		code TEXT PRIMARY KEY,
		desktop_device_id TEXT NOT NULL,
		expires_at DATETIME NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (desktop_device_id) REFERENCES devices(id) ON DELETE CASCADE
	);

	CREATE TABLE IF NOT EXISTS pairings (
		desktop_device_id TEXT NOT NULL,
		mobile_device_id TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (desktop_device_id, mobile_device_id),
		FOREIGN KEY (desktop_device_id) REFERENCES devices(id) ON DELETE CASCADE,
		FOREIGN KEY (mobile_device_id) REFERENCES devices(id) ON DELETE CASCADE
	);

	CREATE INDEX IF NOT EXISTS idx_sessions_device ON sessions(device_id);
	CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
	CREATE INDEX IF NOT EXISTS idx_pairing_codes_desktop ON pairing_codes(desktop_device_id);
	CREATE INDEX IF NOT EXISTS idx_pairings_mobile ON pairings(mobile_device_id);
	`

	_, err := s.db.Exec(schema)
	return err
}

// Close closes the database connection
func (s *Store) Close() error {
	return s.db.Close()
}

// Device operations

// CreateDevice registers a new device
func (s *Store) CreateDevice(ctx context.Context, device *models.Device) error {
	_, err := s.db.ExecContext(ctx,
		"INSERT INTO devices (id, name, token, type) VALUES (?, ?, ?, ?)",
		device.ID, device.Name, device.Token, device.Type,
	)
	return err
}

// GetDeviceByToken retrieves a device by its auth token
func (s *Store) GetDeviceByToken(ctx context.Context, token string) (*models.Device, error) {
	device := &models.Device{}
	err := s.db.QueryRowContext(ctx,
		"SELECT id, name, token, type, created_at FROM devices WHERE token = ?",
		token,
	).Scan(&device.ID, &device.Name, &device.Token, &device.Type, &device.CreatedAt)

	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("device not found")
	}
	return device, err
}

// GetDeviceByID retrieves a device by ID
func (s *Store) GetDeviceByID(ctx context.Context, id string) (*models.Device, error) {
	device := &models.Device{}
	err := s.db.QueryRowContext(ctx,
		"SELECT id, name, token, type, created_at FROM devices WHERE id = ?",
		id,
	).Scan(&device.ID, &device.Name, &device.Token, &device.Type, &device.CreatedAt)

	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("device not found")
	}
	return device, err
}

// ListDevices returns all registered devices
func (s *Store) ListDevices(ctx context.Context) ([]models.Device, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT id, name, token, type, created_at FROM devices ORDER BY created_at DESC",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []models.Device
	for rows.Next() {
		var d models.Device
		if err := rows.Scan(&d.ID, &d.Name, &d.Token, &d.Type, &d.CreatedAt); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

// CreatePairingCode stores a short-lived pairing code for a desktop device.
func (s *Store) CreatePairingCode(ctx context.Context, desktopID, code string, expiresAt time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx,
		"DELETE FROM pairing_codes WHERE desktop_device_id = ? OR expires_at <= ?",
		desktopID, time.Now(),
	); err != nil {
		return err
	}

	if _, err := tx.ExecContext(ctx,
		"INSERT INTO pairing_codes (code, desktop_device_id, expires_at) VALUES (?, ?, ?)",
		code, desktopID, expiresAt,
	); err != nil {
		return err
	}

	return tx.Commit()
}

// ConsumePairingCode exchanges a valid pairing code for a persistent pairing.
func (s *Store) ConsumePairingCode(ctx context.Context, mobileID, code string) (*models.DevicePairing, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, "DELETE FROM pairing_codes WHERE expires_at <= ?", time.Now()); err != nil {
		return nil, err
	}

	var pairing models.DevicePairing
	err = tx.QueryRowContext(ctx, `
		SELECT pc.desktop_device_id, d.name
		FROM pairing_codes pc
		JOIN devices d ON d.id = pc.desktop_device_id
		WHERE pc.code = ? AND pc.expires_at > ?
	`, code, time.Now()).Scan(&pairing.DesktopID, &pairing.DesktopName)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("pairing code not found or expired")
	}
	if err != nil {
		return nil, err
	}

	if err := tx.QueryRowContext(ctx,
		"SELECT name FROM devices WHERE id = ?",
		mobileID,
	).Scan(&pairing.MobileName); err != nil {
		return nil, err
	}
	pairing.MobileID = mobileID

	if _, err := tx.ExecContext(ctx, "DELETE FROM pairing_codes WHERE code = ?", code); err != nil {
		return nil, err
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO pairings (desktop_device_id, mobile_device_id)
		VALUES (?, ?)
		ON CONFLICT(desktop_device_id, mobile_device_id) DO NOTHING
	`, pairing.DesktopID, mobileID); err != nil {
		return nil, err
	}

	if err := tx.QueryRowContext(ctx, `
		SELECT created_at
		FROM pairings
		WHERE desktop_device_id = ? AND mobile_device_id = ?
	`, pairing.DesktopID, mobileID).Scan(&pairing.CreatedAt); err != nil {
		return nil, err
	}

	return &pairing, tx.Commit()
}

// ListPairedDesktopIDs returns all desktop device IDs paired with the given mobile.
func (s *Store) ListPairedDesktopIDs(ctx context.Context, mobileID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT desktop_device_id FROM pairings WHERE mobile_device_id = ?",
		mobileID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// ListPairedMobileIDs returns all mobile device IDs paired with the given desktop.
func (s *Store) ListPairedMobileIDs(ctx context.Context, desktopID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT mobile_device_id FROM pairings WHERE desktop_device_id = ?",
		desktopID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// IsPaired reports whether the given desktop/mobile devices are paired.
func (s *Store) IsPaired(ctx context.Context, desktopID, mobileID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, `
		SELECT COUNT(*)
		FROM pairings
		WHERE desktop_device_id = ? AND mobile_device_id = ?
	`, desktopID, mobileID).Scan(&count)
	return count > 0, err
}

// Session operations

// CreateSession creates a new terminal session
func (s *Store) CreateSession(ctx context.Context, session *models.Session) error {
	status := session.Status
	if status == "" {
		status = "active"
	}
	_, err := s.db.ExecContext(ctx,
		"INSERT INTO sessions (id, device_id, title, layout, status, cols, rows) VALUES (?, ?, ?, ?, ?, ?, ?)",
		session.ID, session.DeviceID, session.Title, session.Layout, status, session.Cols, session.Rows,
	)
	return err
}

// GetSession retrieves a session by ID
func (s *Store) GetSession(ctx context.Context, id string) (*models.Session, error) {
	session := &models.Session{}
	err := s.db.QueryRowContext(ctx,
		"SELECT id, device_id, title, layout, status, cols, rows, created_at FROM sessions WHERE id = ?",
		id,
	).Scan(&session.ID, &session.DeviceID, &session.Title, &session.Layout,
		&session.Status, &session.Cols, &session.Rows, &session.CreatedAt)

	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("session not found")
	}
	return session, err
}

// UpdateSessionStatus updates the status of a session
func (s *Store) UpdateSessionStatus(ctx context.Context, id, status string) error {
	_, err := s.db.ExecContext(ctx,
		"UPDATE sessions SET status = ? WHERE id = ?",
		status, id,
	)
	return err
}

// GetActiveSessions returns all active sessions for a device
func (s *Store) GetActiveSessions(ctx context.Context, deviceID string) ([]models.Session, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT id, device_id, title, layout, status, cols, rows, created_at FROM sessions WHERE device_id = ? AND status = 'active' ORDER BY created_at DESC",
		deviceID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sessions []models.Session
	for rows.Next() {
		var s models.Session
		if err := rows.Scan(&s.ID, &s.DeviceID, &s.Title, &s.Layout,
			&s.Status, &s.Cols, &s.Rows, &s.CreatedAt); err != nil {
			return nil, err
		}
		sessions = append(sessions, s)
	}
	return sessions, rows.Err()
}

// GetAllActiveSessions returns all active sessions across all devices
func (s *Store) GetAllActiveSessions(ctx context.Context) ([]models.Session, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT id, device_id, title, layout, status, cols, rows, created_at FROM sessions WHERE status = 'active' ORDER BY created_at DESC",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var sessions []models.Session
	for rows.Next() {
		var s models.Session
		if err := rows.Scan(&s.ID, &s.DeviceID, &s.Title, &s.Layout,
			&s.Status, &s.Cols, &s.Rows, &s.CreatedAt); err != nil {
			return nil, err
		}
		sessions = append(sessions, s)
	}
	return sessions, rows.Err()
}

// Online status operations

// SetOnline marks a device as online
func (s *Store) SetOnline(ctx context.Context, deviceID string) error {
	now := time.Now()
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO online_status (device_id, connected_at, last_seen) 
		 VALUES (?, ?, ?)
		 ON CONFLICT(device_id) DO UPDATE SET last_seen = excluded.last_seen`,
		deviceID, now, now,
	)
	return err
}

// SetOffline marks a device as offline
func (s *Store) SetOffline(ctx context.Context, deviceID string) error {
	_, err := s.db.ExecContext(ctx,
		"DELETE FROM online_status WHERE device_id = ?",
		deviceID,
	)
	return err
}

// GetOnlineDevices returns all currently online devices
func (s *Store) GetOnlineDevices(ctx context.Context) ([]models.OnlineStatus, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT device_id, connected_at, last_seen FROM online_status",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var statuses []models.OnlineStatus
	for rows.Next() {
		var st models.OnlineStatus
		if err := rows.Scan(&st.DeviceID, &st.ConnectedAt, &st.LastSeen); err != nil {
			return nil, err
		}
		statuses = append(statuses, st)
	}
	return statuses, rows.Err()
}

// IsOnline checks if a device is currently online
func (s *Store) IsOnline(ctx context.Context, deviceID string) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM online_status WHERE device_id = ?",
		deviceID,
	).Scan(&count)
	return count > 0, err
}
