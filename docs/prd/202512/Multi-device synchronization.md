# Kelivo 多端数据同步方案设计

## 一、概述

### 1.1 目标

为 Kelivo 实现跨平台（Android、iOS、Windows、macOS、Linux、Harmony）的实时数据同步，使用户在任意设备上的操作能够自动同步到其他设备。

### 1.2 设计原则

| 原则           | 说明                                       |
| -------------- | ------------------------------------------ |
| **无登录态**   | 保持现有设计，通过共享密钥实现身份识别     |
| **离线优先**   | 本地 Hive 存储为主，网络可用时同步         |
| **端到端加密** | 云端仅存储加密数据，保护用户隐私           |
| **最终一致性** | 采用全序变更日志回放 + 字段级 LWW/按 key 合并，保证多端数据最终一致 |
| **增量同步**   | 仅同步变更数据，减少带宽消耗               |
| **单用户独享** | 每个用户独享 Supabase 实例，无需多租户隔离 |

### 1.3 推荐技术栈

```
┌─────────────────────────────────────────────────────────────┐
│                     客户端 (Flutter)                         │
├─────────────────────────────────────────────────────────────┤
│  Hive (本地存储)  ←→  SyncEngine  ←→  Supabase Client       │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                     云端 (Supabase)                          │
├─────────────────────────────────────────────────────────────┤
│  PostgreSQL (数据存储) + Changelog (增量拉取)                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、当前数据存储结构分析

### 2.1 存储方式概览

项目采用双存储方案：

| 存储方式              | 用途                 | 数据特点                   |
| --------------------- | -------------------- | -------------------------- |
| **Hive**              | 对话、消息、工具事件 | 高频读写、结构化、数据量大 |
| **SharedPreferences** | 配置、助手、设置     | 低频修改、JSON 序列化      |

### 2.2 数据实体分类

#### 第一类：聊天数据（Hive 存储）

| 实体         | Hive Box         | 数据量级    | 同步优先级 |
| ------------ | ---------------- | ----------- | ---------- |
| Conversation | `conversations`  | 中等 (百级) | ⭐⭐⭐ 高  |
| ChatMessage  | `messages`       | 大 (万级)   | ⭐⭐⭐ 高  |
| ToolEvent    | `tool_events_v1` | 中等        | ⭐⭐ 中    |

#### 第二类：助手配置（SharedPreferences）

| 实体                 | Storage Key                 | 数据量级  | 同步优先级 |
| -------------------- | --------------------------- | --------- | ---------- |
| Assistant            | `assistants_v1`             | 小 (十级) | ⭐⭐⭐ 高  |
| AssistantMemory      | `assistant_memories_v1`     | 小        | ⭐⭐ 中    |
| AssistantTag         | `assistant_tags_v1`         | 小        | ⭐⭐ 中    |
| QuickPhrase          | `quick_phrases_v1`          | 小        | ⭐⭐ 中    |
| InstructionInjection | `instruction_injections_v1` | 小        | ⭐⭐ 中    |

#### 第三类：系统配置（SharedPreferences）

| 实体           | Storage Key           | 同步优先级          |
| -------------- | --------------------- | ------------------- |
| ProviderConfig | `provider_configs_v1` | ⭐⭐⭐ 高           |
| 选中模型       | `selected_model_v1`   | ⭐ 低               |
| 主题设置       | `theme_*`             | ⭐ 低（建议不同步） |
| 用户信息       | `user_*`              | ⭐⭐ 中             |
| MCP 配置       | MCP Provider          | ⭐⭐ 中             |

### 2.3 数据关系图

```
                    ┌─────────────────┐
                    │   Assistant     │
                    │   (助手配置)     │
                    └────────┬────────┘
                             │ 1:n
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
    │ Conversation│  │AssistantMem │  │ QuickPhrase │
    │   (对话)     │  │  (记忆)     │  │ (快捷短语)  │
    └──────┬──────┘  └─────────────┘  └─────────────┘
           │ 1:n
           ▼
    ┌─────────────┐
    │ ChatMessage │
    │   (消息)     │
    └──────┬──────┘
           │ 1:n
           ▼
    ┌─────────────┐
    │  ToolEvent  │
    │ (工具调用)   │
    └─────────────┘
```

---

## 三、同步架构设计

### 3.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                           客户端架构                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌───────────┐    ┌───────────────┐    ┌───────────────────────┐  │
│   │   Hive    │◄──►│  SyncEngine   │◄──►│  EncryptionService    │  │
│   │ (本地存储) │    │  (同步引擎)    │    │  (加密服务)           │  │
│   └───────────┘    └───────┬───────┘    └───────────────────────┘  │
│                            │                                        │
│   ┌───────────┐    ┌───────▼───────┐    ┌───────────────────────┐  │
│   │SharedPrefs│◄──►│ChangeTracker  │◄──►│  ConflictResolver     │  │
│   │ (配置存储) │    │ (变更追踪)     │    │  (冲突解决)           │  │
│   └───────────┘    └───────┬───────┘    └───────────────────────┘  │
│                            │                                        │
│                    ┌───────▼───────┐                               │
│                    │ SyncTransport │                               │
│                    │ (传输层)       │                               │
│                    └───────┬───────┘                               │
└────────────────────────────┼────────────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │   Supabase      │
                    │  (云端服务)      │
                    └─────────────────┘
```

### 3.2 核心组件职责

| 组件                  | 职责                                       |
| --------------------- | ------------------------------------------ |
| **SyncEngine**        | 同步流程编排、状态管理、错误处理           |
| **ChangeTracker**     | 监听本地数据变更、生成变更日志             |
| **EncryptionService** | 数据加密/解密、密钥派生                    |
| **ConflictResolver**  | 检测冲突、执行合并策略                     |
| **SyncTransport**     | 网络通信（批量 push / changelog 周期拉取） |

### 3.3 同步模式

#### 推送同步（本地 → 云端）

```
本地修改 → ChangeTracker 捕获 → 加密 → 上传云端 → 写入 sync_changelog
```

#### 拉取同步（云端 → 本地）

```
周期拉取 sync_changelog（since_id 游标，间隔 5-10 秒）→ 拉取对应实体密文 → 解密 → 冲突检测/合并 → 写入本地
```

---

## 四、无登录认证方案

### 4.1 认证机制

由于每个用户使用**独享的 Supabase 服务端**，无需复杂的用户认证。采用**同步密钥**方案：

```
用户配置同步密钥 (Sync Key)
         │
         ▼
  派生加密密钥 (AES-256) ───► 用于端到端加密
         │
         ▼
  派生鉴权密钥 (auth_key) ───► 用于请求签名验证
```

### 4.2 配置项设计

用户需要配置以下信息：

| 配置项       | 说明                               | 示例                      | 必填 |
| ------------ | ---------------------------------- | ------------------------- | ---- |
| 同步服务 URL | 用户自己的 Supabase 项目地址       | `https://xxx.supabase.co` | ✅   |
| Anon Key     | Supabase 公开密钥（配合 RLS 使用） | `eyJhbGciOiJIUzI1...`     | ✅   |
| 同步密钥     | 用于加密数据和生成请求签名         | `my-secret-key-2024`      | ✅   |

> **安全说明**：
>
> - `Anon Key` 是 Supabase 的公开密钥，本身不提供安全保障
> - 真正的安全由 **RLS + 请求签名验证** 实现
> - 从 `同步密钥` 派生 `auth_key`（用于请求签名）与加密密钥（用于端到端加密），即使 Anon Key 泄露也无法操作数据

### 4.3 多端配置同步

支持两种方式在多端配置相同的同步设置：

1. **手动输入**：用户在每个设备上手动输入相同的配置
2. **QR 码扫描**：主设备生成配置二维码，其他设备扫码导入

### 4.4 安全性保障

| 层面             | 措施                                   |
| ---------------- | -------------------------------------- |
| **API 访问控制** | RLS + 请求签名验证，防止未授权访问     |
| **防删除/DoS**   | 数据库级别权限控制，无有效签名无法操作 |
| 传输安全         | HTTPS                                  |
| 存储安全         | AES-256-GCM 端到端加密（强制启用）     |
| 密钥保护         | 本地安全存储（Keychain/Keystore）      |
| **一致性保障**   | 强制加密，无配置选项，彻底杜绝不一致   |

### 4.5 RLS + 请求签名验证（安全核心）

#### 4.5.1 安全威胁分析

即使数据端到端加密，Supabase anon key 泄露仍存在以下风险：

| 攻击类型     | 风险等级 | 后果                                     |
| ------------ | -------- | ---------------------------------------- |
| 删除数据     | ⚠️ 高    | `DELETE FROM sync_messages` 清空所有数据 |
| 插入垃圾数据 | ⚠️ 高    | 占满存储空间                             |
| DoS 攻击     | ⚠️ 高    | 耗尽 Supabase 配额/带宽                  |
| 数据篡改     | ⚠️ 中    | 替换为无效密文                           |
| 窃取元数据   | ⚠️ 中    | device_id、时间戳等                      |

#### 4.5.2 解决方案：RLS + 请求签名（主防 anon key 泄露）

通过 **Row Level Security (RLS)** + **请求签名验证** 实现数据库级别的访问控制：

- 客户端携带 `x-timestamp/x-signature`
- 对于写请求（POST/PATCH/PUT/DELETE）额外携带 `x-nonce`（一次性随机串）与 `x-body-sha256`（请求 body 的 SHA-256，hex/base64 均可，但需双方一致）
- 服务端通过两层机制协同完成校验与防重放：
  - **RLS 层**：对所有读写请求调用 `verify_sync_request()`（该函数**无副作用**，仅负责验签）
    - 校验时间窗（防重放基础门槛）
    - 从仅服务器可读的 `sync_secrets` 取出 `auth_key`
    - 从 PostgREST 请求上下文读取 `method/path`
    - 计算并验证：
      - `message = "{timestamp}\n{method}\n{path}\n{nonce}\n{body_sha256}"`
      - `signature = HMAC-SHA256(auth_key, message)`
  - **Trigger 层（statement 级）**：对写请求通过 `consume_sync_nonce()` 将 `nonce` 写入去重表
    - 同一个 HTTP 请求无论批量写入多少行，都只消费一次 nonce
    - 重复 nonce 直接拒绝（强防重放）

> 说明：此方案的目标是"anon key 泄露也无法读写数据"。不把"数据库拖库后仍不可伪造请求"作为核心目标，因此云端存储 `auth_key` 是可接受的；该字段存放于仅服务器可读的 `sync_secrets` 中。

#### 4.5.3 密钥派生设计

从用户的同步密钥派生多个用途的密钥：

```
用户输入同步密钥 (Sync Key)
         │
         ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  HKDF 密钥派生（使用不同的 info 参数）                        │
   │                                                             │
   │  加密密钥 = HKDF(syncKey, salt, info="encryption")          │
   │       └──► 用于 AES-256-GCM 端到端加密                       │
   │                                                             │
   │  鉴权密钥 = HKDF(syncKey, salt, info="auth")                │
   │       └──► 用于日常请求签名（HMAC）                          │
   │                                                             │
   │  管理密钥 = HMAC-SHA256(auth_key, "kelivo_admin_init")      │
   │       └──► 仅用于初始化签名，之后不再使用                     │
   └─────────────────────────────────────────────────────────────┘
```

**关键设计**：

- 云端存储 `auth_key`（用于验签），存放在仅服务器可读的 `sync_secrets`；客户端不具备直接读取该 key 的权限。
- `admin_key` 从 `auth_key` 派生，用于初始化时的签名验证，确保只有持有正确同步密钥的客户端才能完成初始化。
- 端到端加密仍成立：云端仅存密文与最小元数据，无法解密业务数据。

#### 4.5.4 请求签名格式

客户端每次请求时生成签名：

```dart
// 客户端签名生成
String generateSignature({
  required String syncKey,
  required int timestamp,
  required String method,
  required String path,
  String nonce = '',
  String bodySha256 = '',
}) {
  // 1. 派生鉴权密钥（auth_key）
  final authKey = HKDF(syncKey, salt: "kelivo_sync", info: "auth");

  // 2. 生成签名（绑定 method/path/nonce/body hash）
  final message = "$timestamp\n$method\n$path\n$nonce\n$bodySha256";
  final signature = HMAC_SHA256(authKey, message);

  return base64Encode(signature);
}

// 请求示例
final timestamp = DateTime.now().millisecondsSinceEpoch;
final method = 'POST';
final path = '/rest/v1/sync_messages';
final nonce = generateRandomNonce();
final bodySha256 = sha256Hex(requestBodyBytes);

final signature = generateSignature(
  syncKey: syncKey,
  timestamp: timestamp,
  method: method,
  path: path,
  nonce: nonce,
  bodySha256: bodySha256,
);

// HTTP Headers
headers: {
  'x-timestamp': timestamp.toString(),
  'x-signature': signature,
  'x-nonce': nonce,            // 写请求必带
  'x-body-sha256': bodySha256, // 写请求必带
}
```

#### 4.5.4.1 签名规范化（必须约定一致）

为避免"客户端算出来的签名"和"PostgREST 侧拿到的真实请求上下文"不一致，签名的 `method/path/bodySha256` 需要固定规范。

- `method`：必须使用大写 HTTP 方法（`GET/POST/PATCH/PUT/DELETE`）。
- `path`：必须使用 PostgREST 实际的 `request.path`（不含域名）。
  - 表接口：`/rest/v1/<table>`，例如：`/rest/v1/sync_messages`
  - RPC：`/rest/v1/rpc/<function>`，例如：`/rest/v1/rpc/cleanup_sync_request_nonces`
  - 约定：**不把 query string 纳入签名**（由服务端 `request.path` 决定；客户端只签名路径本体）。
- `x-body-sha256`：写请求必带，且建议固定为 **hex(sha256(bodyBytes))**。
  - `bodyBytes` 必须是"最终发送到网络的原始字节"（例如 JSON 的 UTF-8 字节），避免序列化空格/字段顺序差异。
  - 批量写入（数组 JSON）同样按整个 body 一次计算。

> 备注：如果后续需要把 query string 也纳入签名，应当显式新增字段（例如 `x-query-sha256`）并在服务端/客户端同时落地，避免直接拼接 URL 产生不一致。

#### 4.5.5 数据库验证函数

```sql
-- 启用 pgcrypto 扩展（用于 HMAC）
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 写请求 nonce 去重表（防重放；不需要开放任何客户端权限）
CREATE TABLE IF NOT EXISTS sync_request_nonces (
  nonce TEXT PRIMARY KEY,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

REVOKE ALL ON TABLE sync_request_nonces FROM anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_sync_request_nonces_created_at
  ON sync_request_nonces(created_at);

-- 验证请求签名的函数（无副作用，供 RLS 调用）
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
  -- 从请求头获取参数
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

  -- 获取 auth_key（仅服务器可读；避免与 RLS 互相递归）
  SELECT auth_key INTO v_auth_key FROM sync_secrets WHERE id = 1;

  IF v_auth_key IS NULL THEN
    RETURN FALSE;
  END IF;

  -- 验证签名：HMAC-SHA256(auth_key, "{timestamp}\n{method}\n{path}\n{nonce}\n{body_sha256}")
  v_message := v_timestamp::TEXT || E'\n'
            || v_method || E'\n'
            || v_path || E'\n'
            || coalesce(v_nonce, '') || E'\n'
            || coalesce(v_body_sha256, '');

  v_expected_sig := encode(
    hmac(convert_to(v_message, 'utf8'), v_auth_key, 'sha256'),
    'base64'
  );

  RETURN v_signature = v_expected_sig;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 写请求 nonce 消费（statement 级，避免批量写入时 RLS 每行重复消费 nonce）
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

-- 可选：TTL 清理（保留 7 天 nonce）
CREATE OR REPLACE FUNCTION cleanup_sync_request_nonces()
RETURNS VOID AS $$
BEGIN
  DELETE FROM sync_request_nonces
  WHERE created_at < NOW() - INTERVAL '7 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

#### 4.5.6 RLS 策略配置

```sql
-- 启用 RLS
ALTER TABLE sync_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_assistants ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_changelog ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_config ENABLE ROW LEVEL SECURITY;

-- sync_messages 策略
CREATE POLICY "verify_signature_select" ON sync_messages
  FOR SELECT USING (verify_sync_request());

CREATE POLICY "verify_signature_insert" ON sync_messages
  FOR INSERT WITH CHECK (verify_sync_request());

CREATE POLICY "verify_signature_update" ON sync_messages
  FOR UPDATE USING (verify_sync_request());

CREATE POLICY "verify_signature_delete" ON sync_messages
  FOR DELETE USING (verify_sync_request());

-- 对其他表应用相同策略（sync_conversations, sync_assistants, sync_configs, sync_changelog）
-- ... 省略重复代码 ...

-- sync_config 策略（不允许客户端创建；仅允许读取/更新）
CREATE POLICY "config_select" ON sync_config
  FOR SELECT USING (verify_sync_request());

CREATE POLICY "config_update" ON sync_config
  FOR UPDATE USING (verify_sync_request());
```

#### 4.5.7 同步初始化（客户端自动初始化，零门槛）

采用**管理密钥模式**，实现首台设备自动完成初始化，无需用户执行任何 SQL。

##### 4.5.7.1 核心思路

```
┌─────────────────────────────────────────────────────────────────────┐
│  首台设备（初始化设备）                                               │
├─────────────────────────────────────────────────────────────────────┤
│  1. 用户输入 Supabase URL + Anon Key + 同步密钥                      │
│  2. 客户端派生：                                                     │
│     - auth_key（用于后续请求签名）                                   │
│     - encryption_key（用于端到端加密）                               │
│     - admin_key（用于初始化签名，仅首次使用）                         │
│  3. 检测服务端是否已初始化（调用初始化 RPC）                          │
│     ├─ 已初始化 → 走正常验证流程                                     │
│     └─ 未初始化 → RPC 验证 admin_key 签名后自动写入                  │
│  4. 初始化成功后开始正常同步                                         │
└─────────────────────────────────────────────────────────────────────┘
```

##### 4.5.7.2 密钥派生设计（三密钥）

```
用户输入同步密钥 (Sync Key)
         │
         ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  HKDF 密钥派生（使用不同的 info 参数）                        │
   │                                                             │
   │  加密密钥 = HKDF(syncKey, salt, info="encryption")          │
   │       └──► 用于 AES-256-GCM 端到端加密                       │
   │                                                             │
   │  鉴权密钥 = HKDF(syncKey, salt, info="auth")                │
   │       └──► 用于日常请求签名（HMAC）                          │
   │                                                             │
   │  管理密钥 = HMAC-SHA256(auth_key, "kelivo_admin_init")      │
   │       └──► 仅用于初始化签名，之后不再使用                     │
   └─────────────────────────────────────────────────────────────┘
```

##### 4.5.7.3 初始化 RPC 函数

```sql
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
  v_admin_key := hmac(
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
    hmac(convert_to(v_message, 'utf8'), v_admin_key, 'sha256'),
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

-- 授权 anon 调用此函数
GRANT EXECUTE ON FUNCTION initialize_sync_service TO anon;
```

##### 4.5.7.4 重置/轮换密钥的 RPC（可选）

```sql
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
    hmac(convert_to(v_message, 'utf8'), v_auth_key, 'sha256'),
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

GRANT EXECUTE ON FUNCTION reset_sync_service TO anon;
```

##### 4.5.7.5 客户端初始化流程

```dart
class SyncInitializer {
  Future<InitResult> initializeSync({
    required String supabaseUrl,
    required String anonKey,
    required String syncKey,
  }) async {
    // 1. 派生密钥
    final authKey = await deriveKey(syncKey, info: "auth");
    final encryptionKey = await deriveKey(syncKey, info: "encryption");
    final adminKey = hmacSha256(authKey, "kelivo_admin_init");
    
    // 2. 生成验证数据
    final verificationData = await encrypt(
      "KELIVO_SYNC_VERIFY",
      encryptionKey,
    );
    
    // 3. 调用初始化 RPC
    final client = SupabaseClient(supabaseUrl, anonKey);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final authKeyBase64 = base64Encode(authKey);
    
    // 生成 admin 签名
    final message = "$timestamp\nINITIALIZE\n$authKeyBase64\n$verificationData";
    final adminSignature = base64Encode(hmacSha256(adminKey, message));
    
    final response = await client.rpc('initialize_sync_service', params: {
      'p_auth_key_base64': authKeyBase64,
      'p_verification_data': verificationData,
      'p_admin_signature': adminSignature,
      'p_timestamp': timestamp,
    });
    
    if (response['success'] == true) {
      return InitResult.success();
    } else if (response['error'] == 'already_initialized') {
      // 已初始化，验证密钥正确性
      return await _verifyExistingSetup(client, authKey, encryptionKey);
    } else {
      return InitResult.error(response['error'], response['message']);
    }
  }
  
  Future<InitResult> _verifyExistingSetup(
    SupabaseClient client,
    List<int> authKey,
    List<int> encryptionKey,
  ) async {
    // 用签名请求获取 verification_data 并解密验证
    final config = await client.from('sync_config').select().single();
    final decrypted = await decrypt(config['verification_data'], encryptionKey);
    
    if (decrypted == 'KELIVO_SYNC_VERIFY') {
      return InitResult.success();
    } else {
      return InitResult.error('invalid_key', '同步密钥不正确');
    }
  }
}
```

##### 4.5.7.6 用户体验流程

```
┌─────────────────────────────────────────────────────────────┐
│  同步设置向导                                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  步骤 1/3: 配置 Supabase 服务                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  服务地址    [https://xxx.supabase.co          ]    │   │
│  │  Anon Key    [eyJhbGciOiJIUzI1NiIs...          ]    │   │
│  │                                                     │   │
│  │  💡 如何获取？查看 Supabase 项目设置 → API           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  步骤 2/3: 设置同步密钥                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  同步密钥    [________________________] [🎲 随机生成] │   │
│  │                                                     │   │
│  │  ⚠️ 请妥善保管此密钥，其他设备需要使用相同密钥才能同步 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  步骤 3/3: 初始化服务                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  ● 检测服务状态...                                   │   │
│  │  ● 服务未初始化，正在自动初始化...                    │   │
│  │  ✅ 初始化成功！                                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│                                              [完成设置]     │
└─────────────────────────────────────────────────────────────┘
```

##### 4.5.7.7 其他设备加入

- 使用相同 `syncKey` 调用 `initialize_sync_service`，返回 `already_initialized`。
- 客户端自动切换到验证模式：用签名请求读取 `sync_config.verification_data` 并解密。
- 解密结果 == `KELIVO_SYNC_VERIFY` → 密钥正确，允许开启同步；否则提示"同步密钥不正确"。

##### 4.5.7.8 方案优势

| 对比项     | 旧方案（手动 SQL）     | 新方案（管理密钥模式）       |
| ---------- | ---------------------- | ---------------------------- |
| 用户门槛   | ⚠️ 高（需数据库知识）  | ✅ 低（纯 GUI 操作）         |
| 额外部署   | 无                     | 无（仅需预置 SQL）           |
| 安全性     | ✅ 高                  | ✅ 高（admin_key 签名保护）  |
| 首次使用   | 需执行 SQL             | 客户端自动完成               |
| 密钥轮换   | 需执行 SQL             | 客户端 GUI 操作              |
| 初始化保护 | 依赖数据库权限         | admin_key 签名 + 幂等检查    |

#### 4.5.8 安全性总结

| 攻击场景      | 防护措施                           | 结果              |
| ------------- | ---------------------------------- | ----------------- |
| anon key 泄露 | RLS 要求有效签名（HMAC(auth_key)） | ❌ 无法操作数据库 |
| 重放攻击      | 时间戳 10 分钟有效期 + 写请求 nonce 一次性 | ❌ 重放请求被拒绝 |
| 暴力破解签名  | HMAC-SHA256 + 32 字节 key          | ❌ 计算不可行     |
| 删除/篡改数据 | 必须有有效签名                     | ❌ 无签名无法操作 |

### 4.6 强制端到端加密设计

为彻底杜绝多端加密设置不一致的问题，采用**强制加密**策略：

#### 4.6.1 设计原则

| 原则         | 说明                                       |
| ------------ | ------------------------------------------ |
| **无选项**   | 不提供"是否启用加密"的开关，默认且强制加密 |
| **密钥派生** | 从同步密钥自动派生加密密钥，用户无感知     |
| **零信任**   | 云端永远只存储加密数据，服务端无法解密     |

#### 4.6.2 加密流程

```
用户输入同步密钥 (Sync Key)
         │
         ▼
   ┌─────────────────────────────────────┐
   │  HKDF 密钥派生                       │
   │  加密密钥 = HKDF(sync_key, salt)    │
   └─────────────────────────────────────┘
         │
         ▼
所有数据自动使用 AES-256-GCM 加密后上传
```

#### 4.6.3 优势

| 优势     | 说明                                   |
| -------- | -------------------------------------- |
| 零配置   | 用户只需输入同步密钥，无需理解加密概念 |
| 零风险   | 不存在"忘记开启加密"的情况             |
| 零不一致 | 所有设备行为完全一致                   |
| 隐私保护 | 即使服务端被攻破，数据仍安全           |

#### 4.6.4 密钥验证

新设备加入同步时，通过**验证数据**确认密钥正确：

```
云端存储一条验证记录：
{
  "verification_data": encrypt("KELIVO_SYNC_VERIFY", key),
  "created_at": "..."
}

新设备加入时：
1. 用输入的同步密钥派生加密密钥
2. 尝试解密 verification_data
3. 解密结果 == "KELIVO_SYNC_VERIFY" → 密钥正确
4. 解密失败或结果不匹配 → 密钥错误，拒绝同步
```

---

## 五、数据同步颗粒度设计

### 5.1 同步单元定义

不同数据类型采用不同的同步颗粒度：

| 数据类型       | 同步颗粒度                             | 原因                                                              |
| -------------- | -------------------------------------- | ----------------------------------------------------------------- |
| ChatMessage    | **实体级（新增）+ 字段级（可变字段）** | 新消息是追加；但存在可变字段（如 `translation`），需要字段级 LWW  |
| Conversation   | **字段级别**                           | 标题、置顶等可独立修改；`messageIds` 属于派生索引，不参与云端同步 |
| Assistant      | **字段级别**                           | 各配置项独立性强                                                  |
| ProviderConfig | **实体级别**                           | 配置需完整性                                                      |
| 其他配置       | **实体级别**                           | 数据量小，整体同步                                                |

### 5.2 消息同步策略

消息以"新增追加"为主，但允许部分字段后续更新（见下文），因此需要定义明确的合并规则：

#### 5.2.1 新增消息（Append）

- 客户端生成 `id` 并写入 `sync_messages`，同时在 `sync_changelog` 追加一条 `change_type=CREATE`。
- `content` 等主体字段视为不可变；如需"重新生成"，创建**新消息**（新 `id`），并使用同一 `groupId` + 递增 `version`。

#### 5.2.2 可变字段（Update）

- `translation`：允许后续更新；采用字段级 LWW，**以 changelog 回放顺序为准**（后回放覆盖前回放）。
- 更新时在 `sync_changelog` 追加一条 `change_type=FIELD_UPDATE, affected_fields=["translation"]`。
- `isStreaming`：运行时状态，不进入同步（仅本地 UI 使用）。

#### 5.2.3 消息顺序与 `messageIds`

- `Conversation.messageIds` 是本地派生索引（用于渲染顺序/截断等），**不进入云端同步**。
- 增量拉取并落盘消息后：仅对本次触达的 `conversation_id` 集合重建 `messageIds`。
  - 推荐确定性规则：按 `timestamp` 排序；同一 `groupId` 的各版本保持连续（组锚点为该组最早版本）。

### 5.3 对话元数据冲突解决

对话的元数据（标题、置顶等）采用**字段级 LWW（Last-Write-Wins）**：

> 字段级变更信息保存在 `encrypted_data` 的明文 payload 内部，云端仅看到密文与最小元数据。

```
字段变更记录（逻辑示意，实际在密文内）：
{
  "conversationId": "xxx",
  "field": "title",
  "value": "新标题",
  "changelogId": 123456,
  "deviceId": "device-a"
}
```

合并规则（字段级 LWW）：

- **以 changelog 回放顺序为准**：同一字段谁的 `changelogId` 更大，谁胜出（后回放覆盖前回放）。
- 不依赖客户端时钟（避免跨端时间漂移导致不一致）。

### 5.4 `versionSelections` 同步策略

`Conversation.versionSelections` 记录用户在每个消息组中选择的版本，采用**字段级 LWW（以 groupId 为 key）**：

#### 5.4.1 数据结构

```dart
// Conversation 中的字段
Map<String, int> versionSelections;  // key: groupId, value: 选中的版本号
```

#### 5.4.2 同步策略

```
versionSelections 变更记录（在 encrypted_data 内）：
{
  "conversationId": "xxx",
  "type": "version_selection",
  "groupId": "msg-group-123",
  "selectedVersion": 2,
  "changelogId": 123456,
  "deviceId": "device-a"
}
```

#### 5.4.3 合并规则

1. **按 groupId 独立合并**：每个 groupId 的选择独立处理
2. **以 changelogId 决定胜出**：同一 groupId 的多次修改，changelogId 更大的胜出
3. **增量更新**：只同步变更的 groupId，不整体覆盖

#### 5.4.4 冲突场景示例

```
设备 A：选择 groupId="g1" 的版本 2（changelogId=100）
设备 B：选择 groupId="g1" 的版本 3（changelogId=101）
设备 B：选择 groupId="g2" 的版本 1（changelogId=102）

合并结果：
- g1 → 版本 3（changelogId=101 > 100）
- g2 → 版本 1
```

### 5.5 助手配置冲突解决

助手配置采用**乐观锁 + 字段级合并**：

> 合并依据（字段级版本/时间戳等）保存在 `encrypted_data` 的明文 payload 内部，云端不存 `field_changes`。

```
┌─────────────────────────────────────────────────────────────┐
│ 云端版本: version=3                                          │
├─────────────────────────────────────────────────────────────┤
│ 设备 A 修改 systemPrompt (基于 version=3)                    │
│ 设备 B 修改 temperature (基于 version=3)                     │
├─────────────────────────────────────────────────────────────┤
│ 合并结果: 两个字段都保留，version=4                           │
└─────────────────────────────────────────────────────────────┘
```

---

## 六、云端数据模型设计

### 6.1 Supabase 表结构

> **说明**：由于服务端为用户独享，无需多租户隔离。

#### sync_messages（消息表）

| 字段            | 类型      | 说明                         |
| --------------- | --------- | ---------------------------- |
| id              | UUID      | 消息 ID（客户端生成）        |
| conversation_id | UUID      | 所属对话 ID                  |
| encrypted_data  | TEXT      | 加密的消息数据               |
| created_at      | TIMESTAMP | 创建时间                     |
| updated_at      | TIMESTAMP | 更新时间（用于追踪字段更新） |
| device_id       | TEXT      | 来源设备 ID                  |

#### sync_conversations（对话表）

| 字段           | 类型      | 说明           |
| -------------- | --------- | -------------- |
| id             | UUID      | 对话 ID        |
| encrypted_data | TEXT      | 加密的对话数据 |
| updated_at     | TIMESTAMP | 更新时间       |
| version        | INTEGER   | 乐观锁版本号   |
| deleted        | BOOLEAN   | 软删除标记     |

#### sync_assistants（助手表）

| 字段           | 类型      | 说明           |
| -------------- | --------- | -------------- |
| id             | UUID      | 助手 ID        |
| encrypted_data | TEXT      | 加密的助手配置 |
| updated_at     | TIMESTAMP | 更新时间       |
| version        | INTEGER   | 乐观锁版本号   |
| deleted        | BOOLEAN   | 软删除标记     |

#### sync_configs（配置表）

| 字段           | 类型      | 说明                            |
| -------------- | --------- | ------------------------------- |
| id             | TEXT      | 配置键（如 `provider_configs`） |
| encrypted_data | TEXT      | 加密的配置数据                  |
| updated_at     | TIMESTAMP | 更新时间                        |
| version        | INTEGER   | 乐观锁版本号                    |

#### sync_changelog（变更日志表）

> **定位**：一致性主通道。所有设备通过 `since_id` 增量拉取，保证不丢变更。

| 字段            | 类型      | 说明                                              |
| --------------- | --------- | ------------------------------------------------- |
| id              | BIGSERIAL | 自增 ID（同步游标）                               |
| entity_type     | TEXT      | 实体类型（message/conversation/assistant/config） |
| entity_id       | TEXT      | 实体 ID                                           |
| change_type     | TEXT      | 变更类型（CREATE/FIELD_UPDATE/DELETE）            |
| affected_fields | TEXT      | 受影响字段（JSON 数组，仅 FIELD_UPDATE 时有值）   |
| timestamp       | TIMESTAMP | 变更时间                                          |
| device_id       | TEXT      | 来源设备                                          |

**change_type 说明**：

| change_type  | 说明     | affected_fields                            |
| ------------ | -------- | ------------------------------------------ |
| CREATE       | 新建实体 | NULL                                       |
| FIELD_UPDATE | 字段更新 | `["translation"]` 或 `["title", "pinned"]` |
| DELETE       | 删除实体 | NULL                                       |

#### sync_secrets（同步密钥表，仅服务器可读）

| 字段       | 类型      | 说明                     |
| ---------- | --------- | ------------------------ |
| id         | INTEGER   | 固定为 1（单行密钥）      |
| auth_key   | BYTEA     | HMAC 鉴权密钥（用于验签） |
| created_at | TIMESTAMP | 创建时间                 |

> 说明：该表不需要开启 RLS，但必须 **不授予** `anon/authenticated` 任何权限。

#### sync_config（同步配置表）

| 字段              | 类型      | 说明                               |
| ----------------- | --------- | ---------------------------------- |
| id                | INTEGER   | 固定为 1（单行配置）               |
| verification_data | TEXT      | 加密的验证数据（用于校验同步密钥） |
| created_at        | TIMESTAMP | 创建时间                           |
| device_count      | INTEGER   | 已连接设备数                       |

### 6.2 数据隔离策略

采用 **RLS (Row Level Security)** + **请求签名验证** 实现访问控制：

```sql
-- 所有查询都需要携带有效签名，RLS 自动验证
-- 客户端请求示例：
Headers: {
  "x-timestamp": "1703404800000",
  "x-signature": "base64_encoded_signature"
}

-- RLS 策略自动验证签名有效性
```

### 6.3 索引设计

```sql
-- 创建索引，提升查询性能
CREATE INDEX idx_messages_conversation ON sync_messages(conversation_id);
CREATE INDEX idx_messages_updated ON sync_messages(updated_at);
CREATE INDEX idx_changelog_timestamp ON sync_changelog(timestamp);
CREATE INDEX idx_changelog_entity ON sync_changelog(entity_type, entity_id);
```

### 6.4 完整建表 SQL

```sql
-- 启用 pgcrypto 扩展
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 同步密钥表（仅服务器可读；单行；由初始化 RPC 写入）
CREATE TABLE sync_secrets (
  id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  auth_key BYTEA NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);

REVOKE ALL ON TABLE sync_secrets FROM anon, authenticated;

-- 同步配置表（单行；由初始化 RPC 写入）
CREATE TABLE sync_config (
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
CREATE TABLE sync_messages (
  id UUID PRIMARY KEY,
  conversation_id UUID NOT NULL,
  encrypted_data TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW(),
  device_id TEXT NOT NULL
);

-- 对话表
CREATE TABLE sync_conversations (
  id UUID PRIMARY KEY,
  encrypted_data TEXT NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW(),
  version INTEGER DEFAULT 1,
  deleted BOOLEAN DEFAULT FALSE
);

-- 助手表
CREATE TABLE sync_assistants (
  id UUID PRIMARY KEY,
  encrypted_data TEXT NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW(),
  version INTEGER DEFAULT 1,
  deleted BOOLEAN DEFAULT FALSE
);

-- 配置表
CREATE TABLE sync_configs (
  id TEXT PRIMARY KEY,
  encrypted_data TEXT NOT NULL,
  updated_at TIMESTAMP DEFAULT NOW(),
  version INTEGER DEFAULT 1
);

-- 变更日志表
CREATE TABLE sync_changelog (
  id BIGSERIAL PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  change_type TEXT NOT NULL,
  affected_fields TEXT,
  timestamp TIMESTAMP DEFAULT NOW(),
  device_id TEXT NOT NULL
);

-- 创建索引
CREATE INDEX idx_messages_conversation ON sync_messages(conversation_id);
CREATE INDEX idx_messages_updated ON sync_messages(updated_at);
CREATE INDEX idx_changelog_timestamp ON sync_changelog(timestamp);
CREATE INDEX idx_changelog_entity ON sync_changelog(entity_type, entity_id);

-- 验证签名函数（无副作用，供 RLS 调用）
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
    hmac(convert_to(v_message, 'utf8'), v_auth_key, 'sha256'),
    'base64'
  );

  RETURN v_signature = v_expected_sig;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 写请求 nonce 消费（statement 级）
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

-- TTL 清理（保留 7 天 nonce；可由外部 cron/运维任务定期调用）
CREATE OR REPLACE FUNCTION cleanup_sync_request_nonces()
RETURNS VOID AS $$
BEGIN
  DELETE FROM sync_request_nonces
  WHERE created_at < NOW() - INTERVAL '7 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================================
-- 客户端自动初始化 RPC（管理密钥模式）
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
  v_admin_key := hmac(
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
    hmac(convert_to(v_message, 'utf8'), v_admin_key, 'sha256'),
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
    hmac(convert_to(v_message, 'utf8'), v_auth_key, 'sha256'),
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
```

### 6.5 落地实现细节（部署/权限/运维约束）

#### 6.5.1 权限模型（最小权限）

- `sync_secrets`、`sync_request_nonces`：不对 `anon/authenticated` 授予任何权限（只允许数据库 owner / service_role 访问）。
- 业务表（`sync_messages/sync_conversations/sync_assistants/sync_configs/sync_changelog/sync_config`）：
  - 通过 `GRANT` 允许 `anon`（或 `authenticated`）进行必要的 `SELECT/INSERT/UPDATE/DELETE`；
  - 再由 RLS 统一调用 `verify_sync_request()` 做"无登录鉴权"。
- `sync_config`：只允许 `SELECT/UPDATE`，不允许客户端直接 `INSERT`（通过 `initialize_sync_service` RPC 完成初始化）。
- **初始化 RPC**（`initialize_sync_service`）：
  - 授权 `anon` 调用；
  - 函数内部检查是否已初始化，防止重复初始化；
  - 通过 `admin_key` 签名验证，确保只有持有正确同步密钥的客户端才能初始化。

> 实践建议：直接按"只用 `anon` 角色访问"来设计，避免客户端出现 `authenticated` 相关逻辑；RLS 校验通过后，`anon` 也能正常完成同步。

#### 6.5.2 `SECURITY DEFINER` 安全约束

- `verify_sync_request()` 与 `consume_sync_nonce()` 必须是 `SECURITY DEFINER`，并显式设置 `search_path`（例如固定为 `public`），避免被恶意同名函数/对象劫持。
- `verify_sync_request()` 必须保持 **无副作用**，只做校验：
  - 该函数会在 RLS 评估时频繁调用；有副作用会导致不可控行为。
- 防重放写入（nonce 消费）必须放在 trigger（statement 级）里：
  - 避免批量写入时每行触发一次导致"同一请求 nonce 被重复消费"。

#### 6.5.3 运维：nonce TTL 清理

- `sync_request_nonces` 需要定期清理（例如保留 7 天）。
- 触发方式可选：
  - 外部定时任务（cron/CI 定时）调用一个 RPC（例如 `cleanup_sync_request_nonces()`）。
  - 或者部署一个只做维护 RPC 的 Edge Function（同样通过 `setup_token` 保护），供外部触发。

#### 6.5.4 数据接口与访问路径约定

- 所有签名的 `path` 必须与 PostgREST 实际访问路径一致：
  - 表接口：`/rest/v1/<table>`
  - RPC：`/rest/v1/rpc/<function>`
- 客户端不要自行拼接"可能被重写/代理"的路径（例如包含域名、网关前缀），以 `SupabaseClient` 实际请求路径为准。

---

## 七、同步流程设计

### 7.1 初始化同步

首次配置同步时，客户端自动完成初始化（无需用户执行 SQL）：

```
┌─────────────────────────────────────────────────────────────┐
│                      初始化同步流程                          │
├─────────────────────────────────────────────────────────────┤
│  1. 验证同步配置（URL、Anon Key）                            │
│  2. 从同步密钥派生三个密钥：                                  │
│     - auth_key（用于日常请求签名）                           │
│     - encryption_key（用于端到端加密）                       │
│     - admin_key（用于初始化签名）                            │
│  3. 调用 initialize_sync_service RPC                        │
│     ├─ 返回 success → 首台设备，初始化成功                   │
│     ├─ 返回 already_initialized → 非首台设备，验证密钥      │
│     │   ├─ 用签名请求获取 verification_data                 │
│     │   ├─ 解密结果 == "KELIVO_SYNC_VERIFY" → 密钥正确     │
│     │   └─ 解密失败 → 提示"同步密钥不正确"                  │
│     └─ 返回其他错误 → 提示具体错误信息                       │
│  4. 首次同步：changelog 全量拉取（since_id=0）并落盘          │
│  5. 启动周期拉取（间隔 5-10 秒）                              │
└─────────────────────────────────────────────────────────────┘
```

**用户体验**：用户只需输入 Supabase URL、Anon Key 和同步密钥，点击"开始同步"即可自动完成初始化，无需任何数据库操作。

### 7.2 客户端时钟校准

由于请求签名依赖时间戳验证（10 分钟有效期），客户端设备时间不准确会导致同步失败。为此，客户端需要实现**时钟偏移校准**机制。

#### 7.2.1 问题场景

| 场景 | 后果 |
| ---- | ---- |
| 用户手动修改系统时间 | 签名时间戳超出有效期，所有请求被拒绝 |
| 设备时钟漂移 | 长时间运行后时间偏差累积 |
| NTP 同步失败 | 离线设备时间不准 |

#### 7.2.2 解决方案：时钟偏移校准

```
┌─────────────────────────────────────────────────────────────┐
│                    时钟偏移校准流程                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  首次连接 / 签名验证失败时：                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  1. 发送轻量级请求（如 HEAD 或简单 GET）             │   │
│  │  2. 从响应头获取服务器时间：                         │   │
│  │     - HTTP Date 头：Date: Wed, 25 Dec 2024 10:30:00 GMT │
│  │  3. 计算时钟偏移量：                                 │   │
│  │     clockOffset = serverTime - localTime            │   │
│  │  4. 持久化存储 clockOffset                          │   │
│  │  5. 后续请求使用校准后的时间戳：                     │   │
│  │     timestamp = localTime + clockOffset             │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### 7.2.3 客户端实现

```dart
class ClockCalibrationService {
  static const String _clockOffsetKey = 'sync_clock_offset';
  
  /// 时钟偏移量（毫秒），正值表示本地时间落后于服务器
  int _clockOffset = 0;
  
  /// 获取校准后的时间戳（毫秒）
  int getCalibratedTimestamp() {
    return DateTime.now().millisecondsSinceEpoch + _clockOffset;
  }
  
  /// 初始化时加载持久化的偏移量
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _clockOffset = prefs.getInt(_clockOffsetKey) ?? 0;
  }
  
  /// 从 HTTP 响应校准时钟
  Future<void> calibrateFromResponse(http.Response response) async {
    final dateHeader = response.headers['date'];
    if (dateHeader == null) return;
    
    try {
      // 解析 HTTP Date 头（RFC 7231 格式）
      final serverTime = HttpDate.parse(dateHeader);
      final localTime = DateTime.now();
      
      // 计算偏移量
      _clockOffset = serverTime.millisecondsSinceEpoch - 
                     localTime.millisecondsSinceEpoch;
      
      // 持久化存储
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_clockOffsetKey, _clockOffset);
      
      // 日志记录（仅在偏移量较大时）
      if (_clockOffset.abs() > 5000) {
        debugPrint('时钟偏移校准: ${_clockOffset}ms');
      }
    } catch (e) {
      debugPrint('时钟校准失败: $e');
    }
  }
  
  /// 检测是否需要重新校准（偏移量过大或签名失败时）
  bool needsRecalibration(int? serverTimestamp) {
    if (serverTimestamp == null) return false;
    final localTimestamp = DateTime.now().millisecondsSinceEpoch;
    final drift = (serverTimestamp - localTimestamp - _clockOffset).abs();
    return drift > 300000; // 超过 5 分钟认为需要重新校准
  }
}
```

#### 7.2.4 集成到 SyncTransport

```dart
class SyncTransport {
  final ClockCalibrationService _clockService;
  
  Future<http.Response> request({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    // 使用校准后的时间戳生成签名
    final timestamp = _clockService.getCalibratedTimestamp();
    final signature = generateSignature(
      timestamp: timestamp,
      method: method,
      path: path,
      // ...
    );
    
    final response = await _httpClient.request(
      method: method,
      path: path,
      headers: {
        'x-timestamp': timestamp.toString(),
        'x-signature': signature,
        // ...
      },
      body: body,
    );
    
    // 每次请求后更新时钟校准
    await _clockService.calibrateFromResponse(response);
    
    // 如果签名验证失败，尝试重新校准后重试
    if (response.statusCode == 403 || response.statusCode == 401) {
      final shouldRetry = await _handleAuthFailure(response);
      if (shouldRetry) {
        return request(method: method, path: path, body: body);
      }
    }
    
    return response;
  }
  
  Future<bool> _handleAuthFailure(http.Response response) async {
    // 强制重新校准
    await _clockService.calibrateFromResponse(response);
    
    // 检查是否因时钟问题导致（通过错误信息判断）
    // 如果是时钟问题，返回 true 允许重试一次
    return _clockService._clockOffset.abs() > 1000;
  }
}
```

#### 7.2.5 校准时机

| 时机 | 说明 |
| ---- | ---- |
| **应用启动** | 加载持久化的偏移量 |
| **首次同步** | 初始化时主动校准 |
| **每次请求** | 从响应头静默更新偏移量 |
| **签名失败** | 强制重新校准并重试 |
| **网络恢复** | 离线恢复在线时重新校准 |

#### 7.2.6 用户提示

当检测到设备时间严重偏差（超过 5 分钟）时，可选择性提示用户：

```
┌─────────────────────────────────────────────────────────────┐
│  ⚠️ 设备时间不准确                                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  检测到您的设备时间与服务器时间相差较大，                      │
│  已自动校准以确保同步正常工作。                               │
│                                                             │
│  建议：开启系统的"自动设置时间"功能，                         │
│  以获得更好的同步体验。                                       │
│                                                             │
│                                        [我知道了] [去设置]   │
└─────────────────────────────────────────────────────────────┘
```

### 7.3 增量同步

正常使用时的增量同步：

```
┌─────────────────────────────────────────────────────────────┐
│                      增量同步流程                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  本地变更推送：                                              │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐  │
│  │本地修改  │ → │变更追踪  │ → │  加密   │ → │上传云端  │  │
│  └─────────┘    └─────────┘    └─────────┘    └─────────┘  │
│                                                             │
│  云端变更拉取（周期轮询，间隔 5-10 秒）：                      │
│  ┌──────────────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐│
│  │拉取 changelog 游标 │→│ 拉实体密文│→│  解密   │→│合并本地  ││
│  └──────────────────┘  └─────────┘  └─────────┘  └─────────┘│
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### 7.2.1 增量拉取接口约定（基于 PostgREST）

**拉取 changelog（since_id 游标）**

- 基本查询：按 `id` 升序拉取 `id > since_id` 的记录。
- 建议分页：单次 `limit=200~1000`（根据移动端网络与内存折中）。

示意（不含域名）：

- `GET /rest/v1/sync_changelog?select=*&id=gt.<since_id>&order=id.asc&limit=500`

**按 changelog 回放拉取实体密文**

- 对同一 `entity_type` 的多条记录，应按类型分组后批量拉取实体，减少请求数。
- 消息表可能量大：
  - 按 `conversation_id` + `updated_at` / `id` 做分页；
  - 或按 changelog 涉及的 `entity_id` 批量 `in` 查询（注意 URL 长度限制，必要时分批）。

**写入与幂等**

- `sync_messages`、`sync_conversations`、`sync_assistants`、`sync_configs` 写入建议统一使用"upsert/patch"语义：
  - 同一 `id` 重复写入应幂等（客户端重试/断线重连的常态）。
- `sync_changelog` 只追加：每次本地变更都追加一条变更记录，作为一致性主通道。

补充（落盘后的本地索引维护）：

- 增量回放 `sync_changelog` 并落盘消息后，收集本次触达的 `conversation_id` 集合
- 对这些对话在本地重建 `Conversation.messageIds`（不需要、也不允许把 `messageIds` 同步到云端）

### 7.4 离线同步

网络断开时的处理：

```
┌─────────────────────────────────────────────────────────────┐
│                      离线同步流程                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  离线时：                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  本地修改 → 记录到 pending_changes 队列              │   │
│  │  标记数据为 "待同步" 状态                            │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  恢复在线时：                                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  1. 拉取离线期间的云端变更                           │   │
│  │  2. 与本地 pending_changes 合并                      │   │
│  │  3. 解决冲突                                         │   │
│  │  4. 上传本地变更                                     │   │
│  │  5. 清空 pending_changes 队列                        │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 7.5 冲突解决流程

```
┌─────────────────────────────────────────────────────────────┐
│                      冲突解决流程                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  检测到冲突（本地版本 ≠ 云端基础版本）                        │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  判断冲突类型                                        │   │
│  │  ├─ 消息冲突 → 按字段策略合并（如 translation LWW）   │   │
│  │  ├─ 对话元数据冲突 → 字段级 LWW                      │   │
│  │  ├─ versionSelections 冲突 → 按 groupId 独立 LWW    │   │
│  │  ├─ 助手配置冲突 → 字段级合并                        │   │
│  │  └─ 其他配置冲突 → LWW                               │   │
│  └─────────────────────────────────────────────────────┘   │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  执行合并策略                                        │   │
│  │  生成合并后的新版本                                  │   │
│  │  更新本地和云端                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 八、同步配置数据范围

### 8.1 默认同步数据

| 数据类型      | 默认同步 | 说明             |
| ------------- | -------- | ---------------- |
| 对话 & 消息   | ✅ 是    | 核心数据         |
| 助手配置      | ✅ 是    | 包含系统提示词等 |
| 助手记忆      | ✅ 是    | 上下文相关       |
| 快捷短语      | ✅ 是    | 用户自定义       |
| 指令注入      | ✅ 是    | 用户自定义       |
| Provider 配置 | ✅ 是    | API 密钥等       |
| MCP 配置      | ✅ 是    | 工具配置         |
| 用户信息      | ✅ 是    | 用户名、头像     |

### 8.2 不同步数据

| 数据类型     | 原因         |
| ------------ | ------------ |
| 主题设置     | 设备偏好不同 |
| 窗口布局     | 设备屏幕不同 |
| 本地代理设置 | 网络环境不同 |
| 临时状态     | 运行时数据   |
|              |
|              |

补充（明确不进入同步）：

- `Conversation.messageIds`：派生索引（可从 messages 重建），不同端合并成本高
- `ChatMessage.isStreaming`：运行时状态，仅本地 UI 使用

### 8.3 可选同步数据

用户可自行配置是否同步：

| 数据类型     | 默认 | 说明                   |
| ------------ | ---- | ---------------------- |
| 选中的模型   | 否   | 不同设备可能有不同偏好 |
| 置顶模型列表 | 否   | 设备偏好               |
| 工具事件详情 | 否   | 数据量大，可选同步     |

---

## 九、性能优化策略

### 9.1 批量同步

避免频繁网络请求：

| 策略     | 说明                         |
| -------- | ---------------------------- |
| 变更聚合 | 500ms 内的变更合并为一次请求 |
| 批量上传 | 多条消息打包上传             |
| 分页拉取 | 大量数据分批拉取             |

### 9.2 增量传输

减少数据传输量：

| 策略                           | 说明                   |
| ------------------------------ | ---------------------- |
| changelog 游标过滤（since_id） | 只拉取上次同步后的变更 |
| 批量拉取/分页                  | 只拉取需要的实体密文   |
| 压缩传输                       | 大数据启用 gzip 压缩   |

### 9.3 本地缓存

减少重复计算：

| 策略           | 说明                   |
| -------------- | ---------------------- |
| 同步状态缓存   | 记录每个实体的同步状态 |
| 变更队列持久化 | 离线变更持久化存储     |
| 增量快照       | 定期创建本地快照       |

---

## 十、用户界面设计

### 10.1 同步设置页面

```
┌─────────────────────────────────────────────────────────────┐
│  同步设置                                                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  启用同步                                    [开关]          │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  服务配置                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  服务地址    [________________________]              │   │
│  │  Anon Key    [________________________]              │   │
│  │  同步密钥    [________________________] [生成随机]   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  [扫码导入配置]              [生成分享二维码]                │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  安全设置                                                    │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  🔒 端到端加密                                已启用     │   │
│  │  所有数据使用 AES-256-GCM 加密，云端无法解密              │   │
│  │                                                         │   │
│  │  🛡️ 请求签名验证                              已启用     │   │
│  │  所有请求需携带有效签名，防止未授权访问                    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  同步状态                                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  状态: ● 已连接                                      │   │
│  │  上次同步: 2024-12-24 10:30:00                       │   │
│  │  已同步设备: 3 台                                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  [立即同步]    [查看同步日志]    [重置同步]                  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 同步状态指示

在主界面显示同步状态：

| 状态   | 图标   | 说明               |
| ------ | ------ | ------------------ |
| 已同步 | ● 绿色 | 数据已同步到云端   |
| 同步中 | ◐ 蓝色 | 正在同步           |
| 待同步 | ○ 黄色 | 有未同步的本地变更 |
| 离线   | ● 灰色 | 网络断开           |
| 错误   | ● 红色 | 同步失败           |

### 10.3 冲突提示

当检测到需要用户介入的冲突时：

```
┌─────────────────────────────────────────────────────────────┐
│  ⚠️ 检测到数据冲突                                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  助手 "写作助手" 在多个设备上被修改：                         │
│                                                             │
│  本地版本 (iPhone)           云端版本 (MacBook)              │
│  ┌───────────────────┐      ┌───────────────────┐          │
│  │ 温度: 0.8         │      │ 温度: 0.7         │          │
│  │ 系统提示词: ...   │      │ 系统提示词: ...   │          │
│  └───────────────────┘      └───────────────────┘          │
│                                                             │
│  [使用本地版本]  [使用云端版本]  [手动合并]                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 十一、错误处理

### 11.1 常见错误场景

| 错误场景         | 处理方式                                   |
| ---------------- | ------------------------------------------ |
| 网络断开         | 切换到离线模式，队列变更                   |
| **签名验证失败** | 检查同步密钥是否正确，检查设备时间是否准确 |
| **请求过期**     | 时间戳超过 10 分钟，提示检查设备时间       |
| 服务不可用       | 自动重试，指数退避                         |
| **同步密钥错误** | 解密验证数据失败，提示密钥不正确           |
| 版本冲突         | 执行冲突解决策略                           |
| 存储空间不足     | 提示清理或升级                             |

### 11.2 重试策略

```
首次失败 → 立即重试
第2次失败 → 等待 1 秒
第3次失败 → 等待 2 秒
第4次失败 → 等待 4 秒
...
最大等待 → 60 秒
最大重试 → 10 次后暂停，等待用户手动触发
```

### 11.3 数据恢复

提供数据恢复机制：

| 功能     | 说明                     |
| -------- | ------------------------ |
| 本地备份 | 同步前自动创建本地备份   |
| 云端历史 | 保留最近 30 天的变更历史 |
| 手动回滚 | 支持回滚到指定时间点     |

---

## 十二、实施路线图

### 第一阶段：基础设施（2-3 周）

- [ ] 设计并创建 Supabase 表结构（含初始化 RPC 函数）
- [ ] 配置 RLS 策略和签名验证函数
- [ ] 实现 SyncConfig 配置管理
- [ ] 实现密钥派生（auth_key + encryption_key + admin_key）
- [ ] 实现请求签名生成和验证（HMAC(auth_key)）
- [ ] 实现客户端时钟校准服务（ClockCalibrationService）
- [ ] 实现客户端自动初始化流程（调用 initialize_sync_service RPC）
- [ ] 实现 AES-256 加密/解密服务
- [ ] 实现基础 SyncTransport 层（含签名头、时钟校准集成）

### 第二阶段：核心同步（3-4 周）

- [ ] 实现 ChangeTracker 变更追踪
- [ ] 实现消息同步（追加模式）
- [ ] 实现对话同步（LWW 策略）
- [ ] 实现助手配置同步
- [ ] 实现 changelog 增量拉取（since_id 游标，周期轮询 5-10 秒）

### 第三阶段：冲突处理（2 周）

- [ ] 实现字段级冲突检测
- [ ] 实现 LWW 合并策略
- [ ] 实现乐观锁机制
- [ ] 实现冲突提示 UI

### 第四阶段：离线支持（2 周）

- [ ] 实现离线变更队列
- [ ] 实现网络状态监听
- [ ] 实现离线恢复同步
- [ ] 实现同步状态持久化

### 第五阶段：优化与测试（2 周）

- [ ] 性能优化（批量、增量）
- [ ] 多设备测试
- [ ] 边界情况测试
- [ ] 用户体验优化

---

## 十三、附录

### A. 同步数据加密格式

```json
{
  "v": 1, // 加密版本
  "alg": "AES-256-GCM", // 加密算法
  "iv": "base64_encoded_iv", // 初始化向量
  "data": "base64_encoded_data", // 加密数据
  "tag": "base64_encoded_tag", // 认证标签
  "aad": "base64_encoded_aad" // 附加认证数据（建议绑定 entity/id/version）
}
```

### B. 变更日志格式

```json
{
  "id": 12345,
  "entityType": "message",
  "entityId": "uuid-xxx",
  "changeType": "CREATE",
  "affectedFields": null,
  "timestamp": 1703404800000,
  "deviceId": "device-a"
}
```

**字段更新示例**：

```json
{
  "id": 12346,
  "entityType": "message",
  "entityId": "uuid-xxx",
  "changeType": "FIELD_UPDATE",
  "affectedFields": ["translation"],
  "timestamp": 1703404900000,
  "deviceId": "device-b"
}
```

**versionSelections 更新示例**：

```json
{
  "id": 12347,
  "entityType": "conversation",
  "entityId": "conv-uuid-xxx",
  "changeType": "FIELD_UPDATE",
  "affectedFields": ["versionSelections"],
  "timestamp": 1703405000000,
  "deviceId": "device-a"
}
```

### C. 同步配置示例

```json
{
  "syncEnabled": true,
  "serviceUrl": "https://xxx.supabase.co",
  "anonKey": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "syncKey": "user-defined-sync-key",
  "autoSync": true,
  "syncInterval": 10,
  "syncOnStartup": true,
  "conflictStrategy": "auto"
}
```

> **注意**：
>
> - `anonKey` 是 Supabase 的公开密钥，配合 RLS 策略使用
> - 真正的安全由 `syncKey` 派生的 `auth_key`（请求签名）保障
> - 端到端加密为强制启用，加密密钥从 `syncKey` 自动派生

### D. 客户端签名实现示例

```dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

class SyncAuth {
  final String syncKey;

  // 派生的密钥（缓存）
  late final List<int> _authKey;
  late final List<int> _encryptionKey;
  late final List<int> _adminKey;

  SyncAuth._({required this.syncKey});

  static Future<SyncAuth> create({required String syncKey}) async {
    final auth = SyncAuth._(syncKey: syncKey);
    await auth._deriveKeys();
    return auth;
  }

  Future<void> _deriveKeys() async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final salt = utf8.encode('kelivo_sync_salt');

    // 派生鉴权密钥（用于日常请求签名 / RLS 验签）
    final authKeyResult = await hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(syncKey)),
      nonce: salt,
      info: utf8.encode('auth'),
    );
    _authKey = await authKeyResult.extractBytes();

    // 派生加密密钥（用于端到端加密）
    final encryptionKeyResult = await hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(syncKey)),
      nonce: salt,
      info: utf8.encode('encryption'),
    );
    _encryptionKey = await encryptionKeyResult.extractBytes();

    // 派生管理密钥（仅用于初始化签名）
    // admin_key = HMAC-SHA256(auth_key, "kelivo_admin_init")
    final hmacSha256 = Hmac(sha256, _authKey);
    final adminDigest = hmacSha256.convert(utf8.encode('kelivo_admin_init'));
    _adminKey = adminDigest.bytes;
  }

  String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// 生成请求签名：HMAC-SHA256(auth_key, "{timestamp}\n{method}\n{path}\n{nonce}\n{body_sha256}")
  String generateSignature({
    required int timestamp,
    required String method,
    required String path,
    String nonce = '',
    String bodySha256 = '',
  }) {
    final message = '$timestamp\n$method\n$path\n$nonce\n$bodySha256';
    final hmacSha256 = Hmac(sha256, _authKey);
    final digest = hmacSha256.convert(utf8.encode(message));
    return base64.encode(digest.bytes);
  }

  /// 生成初始化签名：HMAC-SHA256(admin_key, "{timestamp}\nINITIALIZE\n{auth_key_base64}\n{verification_data}")
  String generateAdminSignature({
    required int timestamp,
    required String verificationData,
  }) {
    final message = '$timestamp\nINITIALIZE\n$authKeyBase64\n$verificationData';
    final hmacSha256 = Hmac(sha256, _adminKey);
    final digest = hmacSha256.convert(utf8.encode(message));
    return base64.encode(digest.bytes);
  }

  /// 获取请求头（写请求必须传 bodyBytes，并携带 nonce + body sha256）
  Map<String, String> getAuthHeaders({
    required String method,
    required String path,
    List<int>? bodyBytes,
    String? nonce,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final isWrite = const {'POST', 'PATCH', 'PUT', 'DELETE'}.contains(method);

    final resolvedNonce = isWrite ? (nonce ?? _randomNonce()) : '';
    final bodySha256 = isWrite ? _sha256Hex(bodyBytes ?? const <int>[]) : '';

    return {
      'x-timestamp': timestamp.toString(),
      'x-nonce': resolvedNonce,
      'x-body-sha256': bodySha256,
      'x-signature': generateSignature(
        timestamp: timestamp,
        method: method,
        path: path,
        nonce: resolvedNonce,
        bodySha256: bodySha256,
      ),
    };
  }

  String _randomNonce() {
    // 仅示意：实际可用更强随机（如 Random.secure()）生成 >=16 字节
    final now = DateTime.now().microsecondsSinceEpoch;
    return base64Url.encode(utf8.encode('nonce-$now'));
  }

  /// 获取 auth_key（用于初始化 RPC）
  String get authKeyBase64 => base64.encode(_authKey);

  /// 获取加密密钥
  List<int> get encryptionKey => _encryptionKey;
}
```

### E. 客户端初始化实现示例

```dart
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

class SyncInitializer {
  final SyncAuth _auth;
  final SupabaseClient _client;
  final SyncEncryption _encryption;

  SyncInitializer({
    required SyncAuth auth,
    required SupabaseClient client,
    required SyncEncryption encryption,
  })  : _auth = auth,
        _client = client,
        _encryption = encryption;

  /// 初始化同步服务（首台设备自动初始化，其他设备验证密钥）
  Future<InitResult> initialize() async {
    // 1. 生成验证数据
    final verificationData = await _encryption.encrypt('KELIVO_SYNC_VERIFY');

    // 2. 调用初始化 RPC
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final adminSignature = _auth.generateAdminSignature(
      timestamp: timestamp,
      verificationData: verificationData,
    );

    try {
      final response = await _client.rpc('initialize_sync_service', params: {
        'p_auth_key_base64': _auth.authKeyBase64,
        'p_verification_data': verificationData,
        'p_admin_signature': adminSignature,
        'p_timestamp': timestamp,
      });

      if (response['success'] == true) {
        // 首台设备，初始化成功
        return InitResult.success(isFirstDevice: true);
      } else if (response['error'] == 'already_initialized') {
        // 非首台设备，验证密钥正确性
        return await _verifyExistingSetup();
      } else {
        return InitResult.error(
          response['error'] as String,
          response['message'] as String,
        );
      }
    } catch (e) {
      return InitResult.error('network_error', e.toString());
    }
  }

  /// 验证已初始化服务的密钥正确性
  Future<InitResult> _verifyExistingSetup() async {
    try {
      // 用签名请求获取 verification_data
      final headers = _auth.getAuthHeaders(
        method: 'GET',
        path: '/rest/v1/sync_config',
      );

      final response = await _client
          .from('sync_config')
          .select('verification_data')
          .eq('id', 1)
          .single();

      final verificationData = response['verification_data'] as String;
      final decrypted = await _encryption.decrypt(verificationData);

      if (decrypted == 'KELIVO_SYNC_VERIFY') {
        return InitResult.success(isFirstDevice: false);
      } else {
        return InitResult.error('invalid_key', '同步密钥不正确');
      }
    } catch (e) {
      return InitResult.error('verification_failed', e.toString());
    }
  }
}

class InitResult {
  final bool success;
  final bool? isFirstDevice;
  final String? errorCode;
  final String? errorMessage;

  InitResult._({
    required this.success,
    this.isFirstDevice,
    this.errorCode,
    this.errorMessage,
  });

  factory InitResult.success({required bool isFirstDevice}) => InitResult._(
        success: true,
        isFirstDevice: isFirstDevice,
      );

  factory InitResult.error(String code, String message) => InitResult._(
        success: false,
        errorCode: code,
        errorMessage: message,
      );
}
```

### F. 相关文件路径

| 类型               | 路径                      |
| ------------------ | ------------------------- |
| 数据模型           | `lib/core/models/`        |
| 存储服务           | `lib/core/services/`      |
| Provider           | `lib/core/providers/`     |
| 同步服务（待创建） | `lib/core/services/sync/` |
