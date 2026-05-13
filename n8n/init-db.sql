CREATE DATABASE n8n_db;
CREATE DATABASE evolution_db;

CREATE TABLE IF NOT EXISTS users (
  id            SERIAL PRIMARY KEY,
  remote_jid    TEXT UNIQUE NOT NULL,
  whatsapp_name TEXT,
  status        TEXT DEFAULT 'nuevo',
  last_notified TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS conversations (
  id           SERIAL PRIMARY KEY,
  remote_jid   TEXT NOT NULL,
  step_id      TEXT,
  user_message TEXT,
  bot_response TEXT,
  message_type TEXT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_conv_jid     ON conversations(remote_jid);
CREATE INDEX IF NOT EXISTS idx_conv_created ON conversations(created_at DESC);

CREATE TABLE IF NOT EXISTS system_logs (
  id          SERIAL PRIMARY KEY,
  workflow_id TEXT,
  node_name   TEXT,
  remote_jid  TEXT,
  status      TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Creada automáticamente por error-handler en el primer error,
-- pero mejor crearla a mano para no depender de eso:
CREATE TABLE IF NOT EXISTS failed_messages (
  id            SERIAL PRIMARY KEY,
  remote_jid    TEXT,
  execution_id  TEXT,
  failed_node   TEXT,
  error_message TEXT,
  error_stack   TEXT,
  payload       JSONB,
  retry_count   INTEGER DEFAULT 0,
  status        TEXT DEFAULT 'pending',
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  last_retry_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_failed_status ON failed_messages(status);


CREATE TABLE IF NOT EXISTS config (
  key VARCHAR PRIMARY KEY,
  value TEXT
);

