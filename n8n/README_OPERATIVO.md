# README_OPERATIVO — Bot Admisión v4

## Índice
1. [Arquitectura de workflows](#arquitectura)
2. [Variables de entorno y de n8n](#variables)
3. [Esquema de base de datos](#esquema-bd)
4. [Orden de inicio y activación](#orden-de-inicio)
5. [Validación post-despliegue](#validacion)
6. [Monitoreo y alertas](#monitoreo)
7. [Procedimiento de rollback](#rollback)
8. [Operaciones frecuentes](#operaciones)
9. [Tablas Redis — claves y TTL](#redis-keys)

---

## 1. Arquitectura de workflows <a name="arquitectura"></a>

```
Archivos JSON (importar en este orden exacto):
────────────────────────────────────────────────────────────
 1. error_handler_workflow.json   → id: bot-admision-error-handler
 2. health_check_workflow.json    → id: bot-admision-health-check
 3. ia_analysis_workflow.json     → id: bot-admision-ia-analysis
 4. async_db_workflow.json        → id: bot-admision-async-db
 5. flow_completo_v4.json         → id: bot-admision-v4  ← activar último
────────────────────────────────────────────────────────────
```

### Flujo de datos entre workflows

```
WhatsApp
  │
  ▼
[v4 — Flujo Principal]
  │  ACK 200 inmediato a EvolutionAPI
  │
  ├─ (si falla cualquier nodo) ──▶ [error-handler]
  │                                    └─ DEL lock + DLQ + Gmail alert
  │
  └─ HTTP fire-and-forget ──▶ [async-db]
                                  └─ Postgres INSERT user/conv/log
                                  └─ HTTP fire-and-forget ──▶ [ia-analysis]
                                                                  └─ Gemini + Sheets + Gmail

[health-check]  ← trigger independiente (schedule 1min + webhook GET /health)
```

### Responsabilidades por workflow

| Workflow          | Trigger              | Responsabilidad                                  |
|-------------------|----------------------|--------------------------------------------------|
| v4 principal      | Webhook POST WA      | Validar, construir respuesta, enviar a WA        |
| error-handler     | Error Trigger n8n    | DEL lock, DLQ, alerta admin                      |
| health-check      | Schedule 1min + GET  | Métricas Redis/Postgres, alerta degradación      |
| ia-analysis       | Webhook POST interno | Análisis Gemini, update Sheets, alerta status    |
| async-db          | Webhook POST interno | INSERT usuario/conversación/log, trigger IA      |

---

## 2. Variables de entorno y de n8n <a name="variables"></a>

### 2.1 Variables de entorno del sistema (archivo `.env` del host de n8n)

```env
# ── Infraestructura ──────────────────────────────────────────
EVOLUTION_INSTANCE=nombre_instancia_evolution
EVOLUTION_API_KEY=tu_api_key_evolution

# ── IA ───────────────────────────────────────────────────────
GEMINI_API_KEY=tu_api_key_google_ai_studio

# ── Notificaciones ───────────────────────────────────────────
ADMIN_EMAIL=admin@colegio.edu.ar

# ── Redis REST (Upstash o redis-commander/proxy local) ───────
REDIS_REST_URL=https://xxx.upstash.io
REDIS_REST_TOKEN=xxx_token

# ── Google Sheets ─────────────────────────────────────────────
SPREADSHEET_ID_QA=1AbC...xyz
SPREADSHEET_ID_REGISTROS=1DeF...uvw
```

### 2.2 Variables de n8n (Settings → Variables en la UI)

Estas son leídas con `$env.NOMBRE` desde nodos Code y HTTP Request:

| Variable             | Valor                                                  | Dónde obtenerla                                      |
|----------------------|--------------------------------------------------------|------------------------------------------------------|
| `ASYNC_DB_WEBHOOK_URL` | URL completa del webhook de `bot-admision-async-db`  | Abrir ese workflow → nodo Webhook → copiar URL       |
| `ALERTAS_WEBHOOK_URL`  | URL completa del webhook de `bot-admision-ia-analysis`| Abrir ese workflow → nodo Webhook → copiar URL       |
| `CB_THRESHOLD`         | `5`                                                   | Cantidad de fallos para abrir el circuit breaker     |
| `CB_WINDOW_TTL`        | `60`                                                  | Segundos antes de resetear el contador de fallos     |

### 2.3 Credentials n8n (Settings → Credentials)

| Nombre               | Tipo                    |
|----------------------|-------------------------|
| Redis ORT            | Redis                   |
| Postgres ORT         | PostgreSQL              |
| Google Sheets ORT    | Google Sheets OAuth2    |
| Gmail ORT            | Gmail OAuth2            |

---

## 3. Esquema de base de datos <a name="esquema-bd"></a>

Ejecutar antes del primer despliegue:

```sql
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
```

---

## 4. Orden de inicio y activación <a name="orden-de-inicio"></a>

```bash
# 1. Infraestructura base
docker-compose up -d redis postgres
docker-compose ps   # esperar status = healthy

# 2. EvolutionAPI
docker-compose up -d evolution-api

# 3. n8n
docker-compose up -d n8n

# 4. Crear esquema de BD (una sola vez)
docker exec -i postgres psql -U postgres -d admision < schema.sql

# 5. Importar workflows en n8n UI (Workflows → Import from file)
#    EN ESTE ORDEN:
#    a) error_handler_workflow.json  → Activar
#    b) health_check_workflow.json   → Activar
#    c) ia_analysis_workflow.json    → Activar → copiar URL del nodo Webhook — Alertas
#    d) async_db_workflow.json       → en nodo "HTTP — Trigger IA" pegar la URL de (c) → Activar → copiar URL del nodo Webhook — Async DB
#    e) flow_completo_v4.json        → configurar variables (ver paso 6) → Activar

# 6. Configurar variables en n8n UI → Settings → Variables:
#    ASYNC_DB_WEBHOOK_URL  = URL del webhook de async-db (copiada en paso d)
#    ALERTAS_WEBHOOK_URL   = URL del webhook de ia-analysis (copiada en paso c)
#    CB_THRESHOLD          = 5
#    CB_WINDOW_TTL         = 60

# 7. Registrar webhook en EvolutionAPI
curl -X POST http://localhost:8080/webhook/set/EVOLUTION_INSTANCE \
  -H "apikey: EVOLUTION_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "http://n8n-n8n-1:5678/webhook/whatsapp-webhook",
    "events": ["MESSAGES_UPSERT"]
  }'
```

---

## 5. Validación post-despliegue <a name="validacion"></a>

### 5.1 Health check
```bash
curl -s http://localhost:5678/webhook/health | jq .
# Esperado: { "status": "ok", ... }
```

### 5.2 Test de mensaje de texto
```bash
curl -X POST http://localhost:5678/webhook/whatsapp-webhook \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "key": { "id": "TEST001", "remoteJid": "5491112345678@s.whatsapp.net", "fromMe": false },
      "messageType": "conversation",
      "message": { "conversation": "hola" },
      "pushName": "Test User"
    }
  }'
```

**Verificar secuencialmente:**
- [ ] El curl devuelve 200 OK inmediato
- [ ] El número de prueba recibe el mensaje en WhatsApp
- [ ] `SELECT * FROM conversations ORDER BY created_at DESC LIMIT 1;`
- [ ] `redis-cli GET session:5491112345678` muestra sesión activa
- [ ] El workflow `bot-admision-async-db` aparece en ejecuciones de n8n

### 5.3 Test de chain completo (IA)
```bash
# Enviar 3 mensajes al número de prueba para generar historial
# Luego verificar en n8n que bot-admision-ia-analysis se ejecutó
# y que en Postgres users.status cambió de 'nuevo' a otro valor
SELECT remote_jid, status FROM users WHERE remote_jid = '5491112345678';
```

### 5.4 Test de deduplicación
```bash
# Enviar el mismo message_id dos veces rápido
# El segundo debe terminar silenciosamente (return [] en INCR > 1)
redis-cli GET dedup:TEST001   # debe existir con valor "2"
```

### 5.5 Test de circuit breaker
```bash
# Simular Evolution API caído (5 fallos)
redis-cli SET cb:evolution:count 5 EX 60
# Enviar mensaje → debe lanzar error → error-handler se activa
# Verificar: failed_messages en Postgres y dlq:messages en Redis
redis-cli LLEN dlq:messages

# Resetear
redis-cli DEL cb:evolution:count
```

### 5.6 Test del error handler
```bash
# Verificar que lock:JID se libera ante fallos
redis-cli SET lock:5491112345678 '{"is_processing":true}' EX 60
# Forzar fallo en el flujo principal (ej. Postgres caído)
# Verificar post-error:
redis-cli EXISTS lock:5491112345678   # debe ser 0
# Y que llegó email de error al ADMIN_EMAIL
```

---

## 6. Monitoreo y alertas <a name="monitoreo"></a>

### Endpoint `/health` — response schema
```json
{
  "status": "ok | degraded | error",
  "timestamp": "2025-01-01T12:00:00.000Z",
  "latency_ms": 45,
  "redis": {
    "ok": true,
    "dlq_depth": 0,
    "config_version": 1735000000000,
    "maintenance": false,
    "circuit_breakers": { "evolution": 0, "sheets": 0, "postgres": 0 }
  },
  "postgres": {
    "ok": true,
    "active_users": 42,
    "pending_dlq": 0,
    "msgs_last_5min": 8,
    "success_last_5min": 8,
    "errors_last_5min": 0
  },
  "alerts": []
}
```

### Umbrales de alerta automática (configurados en health-check)
| Condición                  | Severidad | Acción                             |
|----------------------------|-----------|------------------------------------|
| `redis.ok = false`         | error     | Email inmediato, revisar Redis     |
| `postgres.ok = false`      | error     | Email inmediato, revisar Postgres  |
| `dlq_depth > 10`           | degraded  | Email, reprocesar DLQ              |
| `cb_evolution >= 5`        | degraded  | Email, verificar EvolutionAPI      |
| `cb_sheets >= 5`           | degraded  | Email, verificar Google Sheets     |
| `errors_last_5min > 5`     | degraded  | Email, revisar logs n8n            |

---

## 7. Procedimiento de rollback <a name="rollback"></a>

```bash
# 1. Desactivar workflow principal actual
#    n8n UI → bot-admision-v4 → toggle OFF

# 2. Backup del estado actual antes de revertir
docker exec n8n-n8n-1 n8n export:workflow --all \
  --output=/tmp/backup-$(date +%Y%m%d-%H%M).json
docker cp n8n-n8n-1:/tmp/backup-$(date +%Y%m%d-%H%M).json ./backups/

# 3. Importar versión anterior y activar

# 4. Verificar health check
curl -s http://localhost:5678/webhook/health | jq .status
```

### Backup de BD antes de migraciones de esquema
```bash
pg_dump -h localhost -U postgres -d admision \
  > ./backups/backup-$(date +%Y%m%d-%H%M).sql
```

---

## 8. Operaciones frecuentes <a name="operaciones"></a>

### Activar / desactivar modo mantenimiento
```bash
redis-cli SET maintenance_mode 1      # activar
redis-cli DEL maintenance_mode        # desactivar
```

### Activar human handoff en un número
```bash
# El bot deja de responder a este número
JID="5491112345678"
SESSION=$(redis-cli GET session:$JID)
# Editar is_human_active a true y volver a guardar
redis-cli SET session:$JID \
  '{"step_id":"PASO_ACTUAL","is_human_active":true,"timestamp_ms":0}' \
  EX 86400

# Para reactivar el bot:
redis-cli SET session:$JID \
  '{"step_id":"INICIO","is_human_active":false,"timestamp_ms":0}' \
  EX 86400
```

### Forzar actualización de config Q&A (invalidar cache)
```bash
redis-cli DEL config:qa              # próximo mensaje consulta Sheets
redis-cli INCR config:qa:version     # fuerza reset de sesiones activas
```

### Ver y limpiar locks atascados
```bash
redis-cli KEYS "lock:*"              # ver locks activos
redis-cli DEL lock:5491112345678     # liberar lock manual
```

### Reprocesar mensajes de DLQ
```bash
# Ver cantidad
redis-cli LLEN dlq:messages

# Ver el primero sin sacarlo
redis-cli LINDEX dlq:messages -1

# Sacar el más antiguo (RPOP = FIFO)
redis-cli RPOP dlq:messages          # copiar el JSON

# Reprocesar manualmente
curl -X POST http://localhost:5678/webhook/whatsapp-webhook \
  -H "Content-Type: application/json" \
  -d '<payload copiado>'

# Marcar como procesado en Postgres
UPDATE failed_messages SET status = 'resolved', last_retry_at = NOW()
WHERE execution_id = 'xxx';
```

### Resetear circuit breakers manualmente
```bash
redis-cli DEL cb:evolution:count
redis-cli DEL cb:sheets:count
redis-cli DEL cb:postgres:count
```

---

## 9. Tablas Redis — claves y TTL <a name="redis-keys"></a>

| Clave                    | Descripción                              | TTL         | Quién la escribe          |
|--------------------------|------------------------------------------|-------------|---------------------------|
| `dedup:{message_id}`     | Previene mensajes duplicados             | 60s         | v4 — Redis Batch          |
| `lock:{jid}`             | Lock de concurrencia por usuario         | 60s         | v4 — SET Lock             |
| `session:{jid}`          | Estado de conversación del usuario       | 24h         | v4 — SET Sesión           |
| `config:qa`              | Cache de configuración Q&A (Sheets)      | 5min (300s) | v4 — SET Config Cache     |
| `config:qa:version`      | Versión monotónica de la config          | Permanente  | v4 — Normalize + CB       |
| `maintenance_mode`       | Flag global de mantenimiento             | Manual      | Operador (redis-cli)      |
| `cb:evolution:count`     | Fallos consecutivos EvolutionAPI         | 60s         | v4 — CB Evolution Check   |
| `cb:sheets:count`        | Fallos consecutivos Google Sheets        | 60s         | v4 — Normalize + CB       |
| `cb:postgres:count`      | Fallos consecutivos Postgres             | 60s         | (reservado — futuro)      |
| `dlq:messages`           | Lista FIFO de mensajes fallidos          | Permanente  | error-handler             |
| `health:ping`            | Ping de disponibilidad del health check  | 2min        | health-check              |
