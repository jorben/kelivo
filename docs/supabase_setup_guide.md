# Kelivo 多端同步 - Supabase 配置指南

本指南帮助您配置 Supabase 项目以启用 Kelivo 的多端数据同步功能。

## 一、创建 Supabase 项目

### 1.1 注册 Supabase 账号

1. 访问 [Supabase 官网](https://supabase.com)
2. 点击 "Start your project" 注册账号（支持 GitHub 登录）

### 1.2 创建新项目

1. 登录后点击 "New Project"
2. 填写项目信息：
   - **Name**: 自定义项目名称（如 `kelivo-sync`）
   - **Database Password**: 设置数据库密码（请妥善保管）
   - **Region**: 选择离您最近的区域
3. 点击 "Create new project" 并等待项目创建完成（约 2 分钟）

### 1.3 获取项目配置

项目创建完成后，进入 **Project Settings → API**，记录以下信息：

| 配置项 | 位置 | 说明 |
|--------|------|------|
| **Project URL** | API Settings | 格式：`https://xxx.supabase.co` |
| **anon public** | Project API keys | 公开密钥，用于客户端连接 |

> ⚠️ **注意**：`anon` 密钥是公开的，真正的安全由 RLS 策略和请求签名保障。

---

## 二、初始化数据库

### 2.1 执行初始化 SQL

1. 进入 Supabase 控制台
2. 点击左侧菜单 **SQL Editor**
3. 点击 "New query"
4. 复制下方完整 SQL 并执行

```sql
-- ============================================================
-- Kelivo 多端同步 - 数据库初始化脚本
-- 版本: 1.0.0
-- ============================================================

-- 启用 pgcrypto 扩展（在 extensions schema 中）
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================
-- 1. 核心表结构
-- ============================================================

-- 同步密钥表（仅服务器可读；单行；由初始化 RPC 写入）
CREATE TABLE IF NOT EXISTS sync_secrets (
  id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  auth_key BYTEA NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);

REVOKE ALL ON TABLE sync_secrets FROM anon, authenticated;

-- 同步配置表（单行；由初始化 RPC 写入）
CREATE TABLE IF NOT EXISTS sync_config (
  id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  verification_data TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  device_count INTEGER DEFAULT 1
);

-- 写请求 nonce 去重表（防重放；不需要开放任何客户端权限）
CREATE TABLE IF NOT EXISTS sync_request_nonces (
  nonce TEXT PRIMARY KEY,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

REVOKE ALL ON TABLE sync_request_nonces FROM anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_sync_request_nonces_created_at
  ON sync_request_nonces(created_at);

-- 消息表
CREATE TABLE IF NOT EXISTS sync_messages (
  id UUID PRIMARY KEY,
  conversation_id UUID NOT NULL,
  encrypted_data TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  device_id TEXT NOT NULL
);

-- 对话表
CREATE TABLE IF NOT EXISTS sync_conversations (
  id UUID PRIMARY KEY,
  encrypted_data TEXT NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW(),
  version INTEGER DEFAULT 1,
  deleted BOOLEAN DEFAULT FALSE
);

-- 助手表
CREATE TABLE IF NOT EXISTS sync_assistants (
  id UUID PRIMARY KEY,
  encrypted_data TEXT NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW(),
  version INTEGER DEFAULT 1,
  deleted BOOLEAN DEFAULT FALSE
);

-- 配置表
CREATE TABLE IF NOT EXISTS sync_configs (
  id TEXT PRIMARY KEY,
  encrypted_data TEXT NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW(),
  version INTEGER DEFAULT 1
);

-- 变更日志表
CREATE TABLE IF NOT EXISTS sync_changelog (
  id BIGSERIAL PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  change_type TEXT NOT NULL,
  affected_fields TEXT,
  timestamp TIMESTAMP DEFAULT NOW(),
  device_id TEXT NOT NULL
);

-- ============================================================
-- 2. 索引
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_messages_conversation ON sync_messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_messages_updated ON sync_messages(updated_at);
CREATE INDEX IF NOT EXISTS idx_changelog_timestamp ON sync_changelog(timestamp);
CREATE INDEX IF NOT EXISTS idx_changelog_entity ON sync_changelog(entity_type, entity_id);

-- ============================================================
-- 3. 验证签名函数（无副作用，供 RLS 调用）
-- ============================================================

CREATE OR REPLACE FUNCTION verify_sync_request()
RETURNS BOOLEAN AS $$
DECLARE
  v_timestamp BIGINT;
  v_signature TEXT;
  v_nonce TEXT;
  v_body_sha256 TEXT;
  v_method TEXT;
  v_path TEXT;
  v_auth_key BYTEA;
  v_expected_sig TEXT;
  v_current_time BIGINT;
  v_message TEXT;
BEGIN
  v_timestamp := (current_setting('request.headers', true)::json->>'x-timestamp')::BIGINT;
  v_signature := current_setting('request.headers', true)::json->>'x-signature';
  v_nonce := current_setting('request.headers', true)::json->>'x-nonce';
  v_body_sha256 := current_setting('request.headers', true)::json->>'x-body-sha256';

  -- 必须使用服务端请求上下文的 method/path（避免客户端伪造）
  v_method := current_setting('request.method', true);
  v_path := current_setting('request.path', true);

  IF v_timestamp IS NULL OR v_signature IS NULL OR v_method IS NULL OR v_path IS NULL THEN
    RETURN FALSE;
  END IF;

  -- 时间戳验证（10分钟有效期，兼容设备时间偏差）
  v_current_time := EXTRACT(EPOCH FROM NOW()) * 1000;
  IF ABS(v_current_time - v_timestamp) > 600000 THEN
    RETURN FALSE;
  END IF;

  -- 写请求必须带 nonce 与 body hash（用于绑定请求体，便于客户端批量上传）
  IF v_method IN ('POST', 'PATCH', 'PUT', 'DELETE') THEN
    IF v_nonce IS NULL OR length(v_nonce) < 16 THEN
      RETURN FALSE;
    END IF;
    IF v_body_sha256 IS NULL OR length(v_body_sha256) < 16 THEN
      RETURN FALSE;
    END IF;
  ELSE
    v_nonce := coalesce(v_nonce, '');
    v_body_sha256 := coalesce(v_body_sha256, '');
  END IF;

  SELECT auth_key INTO v_auth_key FROM sync_secrets WHERE id = 1;

  IF v_auth_key IS NULL THEN
    RETURN FALSE;
  END IF;

  v_message := v_timestamp::TEXT || E'\n'
            || v_method || E'\n'
            || v_path || E'\n'
            || coalesce(v_nonce, '') || E'\n'
            || coalesce(v_body_sha256, '');

  v_expected_sig := encode(
    extensions.hmac(convert_to(v_message, 'utf8'), v_auth_key, 'sha256'),
    'base64'
  );

  RETURN v_signature = v_expected_sig;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 4. 写请求 nonce 消费（statement 级）
-- ============================================================

CREATE OR REPLACE FUNCTION consume_sync_nonce()
RETURNS TRIGGER AS $$
DECLARE
  v_method TEXT;
  v_nonce TEXT;
BEGIN
  v_method := current_setting('request.method', true);
  IF v_method IS NULL THEN
    RAISE EXCEPTION 'missing request.method';
  END IF;

  IF v_method IN ('POST', 'PATCH', 'PUT', 'DELETE') THEN
    v_nonce := current_setting('request.headers', true)::json->>'x-nonce';
    IF v_nonce IS NULL OR length(v_nonce) < 16 THEN
      RAISE EXCEPTION 'invalid x-nonce';
    END IF;

    BEGIN
      INSERT INTO sync_request_nonces(nonce) VALUES (v_nonce);
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'replayed request nonce';
    END;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- statement-level triggers（防止批量写入时 nonce 被按行重复消费）
DROP TRIGGER IF EXISTS t_consume_sync_nonce_messages ON sync_messages;
CREATE TRIGGER t_consume_sync_nonce_messages
BEFORE INSERT OR UPDATE OR DELETE ON sync_messages
FOR EACH STATEMENT EXECUTE FUNCTION consume_sync_nonce();

DROP TRIGGER IF EXISTS t_consume_sync_nonce_conversations ON sync_conversations;
CREATE TRIGGER t_consume_sync_nonce_conversations
BEFORE INSERT OR UPDATE OR DELETE ON sync_conversations
FOR EACH STATEMENT EXECUTE FUNCTION consume_sync_nonce();

DROP TRIGGER IF EXISTS t_consume_sync_nonce_assistants ON sync_assistants;
CREATE TRIGGER t_consume_sync_nonce_assistants
BEFORE INSERT OR UPDATE OR DELETE ON sync_assistants
FOR EACH STATEMENT EXECUTE FUNCTION consume_sync_nonce();

DROP TRIGGER IF EXISTS t_consume_sync_nonce_configs ON sync_configs;
CREATE TRIGGER t_consume_sync_nonce_configs
BEFORE INSERT OR UPDATE OR DELETE ON sync_configs
FOR EACH STATEMENT EXECUTE FUNCTION consume_sync_nonce();

DROP TRIGGER IF EXISTS t_consume_sync_nonce_changelog ON sync_changelog;
CREATE TRIGGER t_consume_sync_nonce_changelog
BEFORE INSERT OR UPDATE OR DELETE ON sync_changelog
FOR EACH STATEMENT EXECUTE FUNCTION consume_sync_nonce();

DROP TRIGGER IF EXISTS t_consume_sync_nonce_config ON sync_config;
CREATE TRIGGER t_consume_sync_nonce_config
BEFORE UPDATE ON sync_config
FOR EACH STATEMENT EXECUTE FUNCTION consume_sync_nonce();

-- ============================================================
-- 5. TTL 清理函数（保留 7 天 nonce）
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_sync_request_nonces()
RETURNS VOID AS $$
BEGIN
  DELETE FROM sync_request_nonces
  WHERE created_at < NOW() - INTERVAL '7 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================================
-- 6. 客户端自动初始化 RPC
-- ============================================================

-- 初始化同步服务（仅允许未初始化时调用）
CREATE OR REPLACE FUNCTION initialize_sync_service(
  p_auth_key_base64 TEXT,
  p_verification_data TEXT,
  p_admin_signature TEXT,
  p_timestamp BIGINT
)
RETURNS JSON AS $$
DECLARE
  v_existing_count INTEGER;
  v_current_time BIGINT;
  v_admin_key BYTEA;
  v_expected_sig TEXT;
  v_message TEXT;
BEGIN
  -- 1. 检查是否已初始化
  SELECT COUNT(*) INTO v_existing_count FROM sync_secrets WHERE id = 1;
  IF v_existing_count > 0 THEN
    RETURN json_build_object(
      'success', false,
      'error', 'already_initialized',
      'message', '同步服务已初始化，如需重置请使用重置功能'
    );
  END IF;

  -- 2. 时间戳验证（10分钟有效期）
  v_current_time := EXTRACT(EPOCH FROM NOW()) * 1000;
  IF ABS(v_current_time - p_timestamp) > 600000 THEN
    RETURN json_build_object(
      'success', false,
      'error', 'timestamp_expired',
      'message', '请求已过期，请检查设备时间'
    );
  END IF;

  -- 3. 从 auth_key 派生 admin_key 并验证签名
  --    admin_key = HMAC-SHA256(auth_key, "kelivo_admin_init")
  v_admin_key := extensions.hmac(
    convert_to('kelivo_admin_init', 'utf8'),
    decode(p_auth_key_base64, 'base64'),
    'sha256'
  );

  -- 4. 验证 admin_signature
  --    message = "{timestamp}\nINITIALIZE\n{auth_key_base64}\n{verification_data}"
  v_message := p_timestamp::TEXT || E'\n'
            || 'INITIALIZE' || E'\n'
            || p_auth_key_base64 || E'\n'
            || p_verification_data;

  v_expected_sig := encode(
    extensions.hmac(convert_to(v_message, 'utf8'), v_admin_key, 'sha256'),
    'base64'
  );

  IF p_admin_signature != v_expected_sig THEN
    RETURN json_build_object(
      'success', false,
      'error', 'invalid_signature',
      'message', '签名验证失败'
    );
  END IF;

  -- 5. 写入初始化数据
  INSERT INTO sync_secrets(id, auth_key)
  VALUES (1, decode(p_auth_key_base64, 'base64'));

  INSERT INTO sync_config(id, verification_data, device_count)
  VALUES (1, p_verification_data, 1);

  RETURN json_build_object(
    'success', true,
    'message', '同步服务初始化成功'
  );

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object(
    'success', false,
    'error', 'internal_error',
    'message', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 授权 anon 调用初始化函数
GRANT EXECUTE ON FUNCTION initialize_sync_service TO anon;

-- 验证同步密钥（用于非首台设备验证）
CREATE OR REPLACE FUNCTION verify_sync_key(
  p_auth_key_base64 TEXT,
  p_timestamp BIGINT,
  p_signature TEXT
)
RETURNS JSON AS $$
DECLARE
  v_current_time BIGINT;
  v_stored_auth_key BYTEA;
  v_admin_key BYTEA;
  v_expected_sig TEXT;
  v_message TEXT;
  v_verification_data TEXT;
BEGIN
  -- 1. 检查是否已初始化
  SELECT auth_key INTO v_stored_auth_key FROM sync_secrets WHERE id = 1;
  IF v_stored_auth_key IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'not_initialized',
      'message', '同步服务未初始化'
    );
  END IF;

  -- 2. 时间戳验证（10分钟有效期）
  v_current_time := EXTRACT(EPOCH FROM NOW()) * 1000;
  IF ABS(v_current_time - p_timestamp) > 600000 THEN
    RETURN json_build_object(
      'success', false,
      'error', 'timestamp_expired',
      'message', '请求已过期'
    );
  END IF;

  -- 3. 验证 auth_key 是否匹配
  IF v_stored_auth_key != decode(p_auth_key_base64, 'base64') THEN
    RETURN json_build_object(
      'success', false,
      'error', 'invalid_key',
      'message', '同步密钥不正确'
    );
  END IF;

  -- 4. 派生 admin_key 并验证签名
  v_admin_key := extensions.hmac(
    convert_to('kelivo_admin_init', 'utf8'),
    decode(p_auth_key_base64, 'base64'),
    'sha256'
  );

  -- 签名消息格式: "{timestamp}\nINITIALIZE\n{auth_key_base64}\n"
  v_message := p_timestamp::TEXT || E'\n'
            || 'INITIALIZE' || E'\n'
            || p_auth_key_base64 || E'\n'
            || '';

  v_expected_sig := encode(
    extensions.hmac(convert_to(v_message, 'utf8'), v_admin_key, 'sha256'),
    'base64'
  );

  IF p_signature != v_expected_sig THEN
    RETURN json_build_object(
      'success', false,
      'error', 'invalid_signature',
      'message', '签名验证失败'
    );
  END IF;

  -- 5. 返回 verification_data 供客户端解密验证
  SELECT verification_data INTO v_verification_data FROM sync_config WHERE id = 1;

  RETURN json_build_object(
    'success', true,
    'verification_data', v_verification_data
  );

EXCEPTION WHEN OTHERS THEN
  RETURN json_build_object(
    'success', false,
    'error', 'internal_error',
    'message', SQLERRM
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 授权 anon 调用验证函数
GRANT EXECUTE ON FUNCTION verify_sync_key TO anon;

-- 重置同步服务（需要当前有效的 auth_key 签名）
CREATE OR REPLACE FUNCTION reset_sync_service(
  p_new_auth_key_base64 TEXT,
  p_new_verification_data TEXT,
  p_signature TEXT,
  p_timestamp BIGINT,
  p_nonce TEXT
)
RETURNS JSON AS $$
DECLARE
  v_current_time BIGINT;
  v_auth_key BYTEA;
  v_expected_sig TEXT;
  v_message TEXT;
BEGIN
  -- 1. 验证当前签名（使用现有 auth_key）
  SELECT auth_key INTO v_auth_key FROM sync_secrets WHERE id = 1;
  IF v_auth_key IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'not_initialized',
      'message', '同步服务未初始化'
    );
  END IF;

  -- 2. 时间戳验证
  v_current_time := EXTRACT(EPOCH FROM NOW()) * 1000;
  IF ABS(v_current_time - p_timestamp) > 600000 THEN
    RETURN json_build_object('success', false, 'error', 'timestamp_expired');
  END IF;

  -- 3. nonce 防重放
  BEGIN
    INSERT INTO sync_request_nonces(nonce) VALUES (p_nonce);
  EXCEPTION WHEN unique_violation THEN
    RETURN json_build_object('success', false, 'error', 'replayed_request');
  END;

  -- 4. 验证签名
  v_message := p_timestamp::TEXT || E'\n'
            || 'RESET' || E'\n'
            || p_new_auth_key_base64 || E'\n'
            || p_new_verification_data || E'\n'
            || p_nonce;

  v_expected_sig := encode(
    extensions.hmac(convert_to(v_message, 'utf8'), v_auth_key, 'sha256'),
    'base64'
  );

  IF p_signature != v_expected_sig THEN
    RETURN json_build_object('success', false, 'error', 'invalid_signature');
  END IF;

  -- 5. 更新密钥
  UPDATE sync_secrets SET auth_key = decode(p_new_auth_key_base64, 'base64') WHERE id = 1;
  UPDATE sync_config SET verification_data = p_new_verification_data WHERE id = 1;

  RETURN json_build_object('success', true, 'message', '同步密钥已重置');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 授权 anon 调用重置函数
GRANT EXECUTE ON FUNCTION reset_sync_service TO anon;

-- ============================================================
-- 7. RLS 策略
-- ============================================================

-- 启用 RLS
ALTER TABLE sync_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_assistants ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_changelog ENABLE ROW LEVEL SECURITY;

-- sync_config 策略（不允许客户端创建；仅允许读取/更新）
CREATE POLICY "config_select" ON sync_config FOR SELECT USING (verify_sync_request());
CREATE POLICY "config_update" ON sync_config FOR UPDATE USING (verify_sync_request());

-- sync_messages 策略
CREATE POLICY "messages_select" ON sync_messages FOR SELECT USING (verify_sync_request());
CREATE POLICY "messages_insert" ON sync_messages FOR INSERT WITH CHECK (verify_sync_request());
CREATE POLICY "messages_update" ON sync_messages FOR UPDATE USING (verify_sync_request());
CREATE POLICY "messages_delete" ON sync_messages FOR DELETE USING (verify_sync_request());

-- sync_conversations 策略
CREATE POLICY "conversations_select" ON sync_conversations FOR SELECT USING (verify_sync_request());
CREATE POLICY "conversations_insert" ON sync_conversations FOR INSERT WITH CHECK (verify_sync_request());
CREATE POLICY "conversations_update" ON sync_conversations FOR UPDATE USING (verify_sync_request());
CREATE POLICY "conversations_delete" ON sync_conversations FOR DELETE USING (verify_sync_request());

-- sync_assistants 策略
CREATE POLICY "assistants_select" ON sync_assistants FOR SELECT USING (verify_sync_request());
CREATE POLICY "assistants_insert" ON sync_assistants FOR INSERT WITH CHECK (verify_sync_request());
CREATE POLICY "assistants_update" ON sync_assistants FOR UPDATE USING (verify_sync_request());
CREATE POLICY "assistants_delete" ON sync_assistants FOR DELETE USING (verify_sync_request());

-- sync_configs 策略
CREATE POLICY "configs_select" ON sync_configs FOR SELECT USING (verify_sync_request());
CREATE POLICY "configs_insert" ON sync_configs FOR INSERT WITH CHECK (verify_sync_request());
CREATE POLICY "configs_update" ON sync_configs FOR UPDATE USING (verify_sync_request());
CREATE POLICY "configs_delete" ON sync_configs FOR DELETE USING (verify_sync_request());

-- sync_changelog 策略
CREATE POLICY "changelog_select" ON sync_changelog FOR SELECT USING (verify_sync_request());
CREATE POLICY "changelog_insert" ON sync_changelog FOR INSERT WITH CHECK (verify_sync_request());

-- ============================================================
-- 8. 授权
-- ============================================================

-- 授权 anon 角色访问业务表
GRANT SELECT, INSERT, UPDATE, DELETE ON sync_messages TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON sync_conversations TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON sync_assistants TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON sync_configs TO anon;
GRANT SELECT, INSERT ON sync_changelog TO anon;
GRANT SELECT, UPDATE ON sync_config TO anon;
GRANT USAGE, SELECT ON SEQUENCE sync_changelog_id_seq TO anon;

-- ============================================================
-- 初始化完成
-- ============================================================
```

### 2.2 验证初始化

执行完成后，在 **Table Editor** 中应该能看到以下表：

- `sync_secrets` - 同步密钥表
- `sync_config` - 同步配置表
- `sync_request_nonces` - 请求去重表
- `sync_messages` - 消息表
- `sync_conversations` - 对话表
- `sync_assistants` - 助手表
- `sync_configs` - 配置表
- `sync_changelog` - 变更日志表

---

## 三、在 Kelivo 中配置同步

### 3.1 打开同步设置

1. 打开 Kelivo 应用
2. 进入 **设置 → 数据同步**
3. 点击 **数据同步** 标签页

### 3.2 填写配置信息

| 配置项 | 说明 | 示例 |
|--------|------|------|
| **服务地址** | Supabase 项目 URL | `https://xxx.supabase.co` |
| **Anon Key** | Supabase 公开密钥 | `eyJhbGciOiJIUzI1...` |
| **同步密钥** | 自定义密钥（用于加密和签名） | 建议使用随机生成 |

### 3.3 完成初始化

1. 点击 **开始同步**
2. 首台设备会自动初始化服务
3. 其他设备使用相同配置即可加入同步

---

## 四、多设备同步

### 4.1 方式一：手动输入

在每个设备上输入相同的：
- 服务地址
- Anon Key
- 同步密钥

### 4.2 方式二：扫码导入

1. 在已配置的设备上点击 **生成分享二维码**
2. 在新设备上点击 **扫码导入配置**
3. 扫描二维码完成配置

---

## 五、安全说明

### 5.1 端到端加密

- 所有数据使用 **AES-256-GCM** 加密后上传
- 加密密钥从同步密钥派生，**不会上传到服务器**
- 即使服务器被攻破，数据仍然安全

### 5.2 请求签名

- 每个请求都携带 HMAC-SHA256 签名
- 签名密钥从同步密钥派生
- 防止未授权访问和重放攻击

### 5.3 密钥安全

- **同步密钥** 是唯一需要保管的密钥
- 请勿将同步密钥分享给他人
- 如果密钥泄露，请使用 **重置同步** 功能更换密钥

---

## 六、常见问题

### Q1: 初始化失败，提示"签名验证失败"

**原因**：设备时间不准确

**解决**：
1. 检查设备时间是否准确
2. 开启系统的"自动设置时间"功能

### Q2: 同步失败，提示"请求已过期"

**原因**：设备时间与服务器时间相差超过 10 分钟

**解决**：同上，校准设备时间

### Q3: 其他设备无法加入同步

**原因**：同步密钥不一致

**解决**：
1. 确保所有设备使用完全相同的同步密钥
2. 建议使用扫码导入功能

### Q4: 如何重置同步？

1. 进入 **设置 → 数据同步**
2. 点击 **重置同步**
3. 输入新的同步密钥
4. 其他设备需要使用新密钥重新配置

---

## 七、数据库维护（可选）

### 7.1 清理过期 nonce

建议定期执行以下 SQL 清理 7 天前的 nonce 记录：

```sql
SELECT cleanup_sync_request_nonces();
```

可以在 Supabase 中设置定时任务（Cron Job）自动执行。

### 7.2 监控存储空间

在 Supabase 控制台的 **Database → Database Settings** 中可以查看存储使用情况。

---

## 八、技术支持

如有问题，请：
1. 查看 [Kelivo 文档](https://github.com/xxx/kelivo)
2. 提交 [Issue](https://github.com/xxx/kelivo/issues)
