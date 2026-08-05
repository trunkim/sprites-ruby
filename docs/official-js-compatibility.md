# Sprites 官方 JS SDK 兼容基线

## 审计基线

- 官方仓库：<https://github.com/superfly/sprites-js>
- revision：`7aa6fab826b3ae373ac0da6c6a5479ad7d197744`（tag `v0.2.0`）
- revision 时间：2026-08-05 10:03:08 -0500
- revision 标题：`Merge pull request #23 from superfly/alex/add-client-attribution`
- 官方测试：`npm test` 为 106 tests、0 failures；需要 provider token 的 integration tests 未执行。

本文件固定 wire contract 基线，不要求 Ruby 复制 JavaScript 的 Promise、EventEmitter
或命名风格。Ruby API 保持同步、Enumerable 与 `snake_case`，但 endpoint、字段、终态、
错误和资源生命周期必须等价。

## 功能矩阵

| 官方 JS surface | Ruby surface | 关键测试 |
|---|---|---|
| create/get/list/watch/listAll/delete/upgrade/restart/check/update/createToken | `Client` management 同名 snake_case 方法 | `management_spec.rb`、`management_surface_spec.rb` |
| spawn/exec/execFile | `Sprite#command` + `Cmd#start/run/output` | `cmd_spec.rb` |
| execFileHTTP | `Sprite#exec_file_http` | `http_exec_spec.rb`、`real_http_integration_spec.rb` |
| create/attach/list/kill session | `create_session`、`attach_session`、`list_sessions`、`kill_session` | `sessions_spec.rb`、`cmd_spec.rb` |
| watchPorts | `Sprite#watch_ports` | `watch_spec.rb` |
| checkpoint create/list/get/restore | 对应 checkpoint 方法与 typed streams | `checkpoints_spec.rb`、`streams_spec.rb` |
| service CRUD/start/stop/restart/logs/signal | 对应 service 方法；`service_logs`/`get_service_logs` 均可用 | `services_spec.rb` |
| network/privileges/resources policies | 对应 policy 方法 | `policy_spec.rb` |
| filesystem read/write/readdir/mkdir/rm/stat/rename/copy/chmod/exists/chown/watch/append/JSON | `SpriteFS` 对应 Ruby 方法 | `filesystem_spec.rb`、`watch_spec.rb` |
| proxy socket/port/ports | `proxy_socket`、`proxy_port`、`proxy_ports` | `proxy_spec.rb` |
| control connection | Ruby 作为内部 bounded pool，供 Cmd 与 filesystem control 复用，不暴露 JS EventEmitter API | `control_pool_spec.rb`、`filesystem_control_spec.rb` |
| client attribution | `ClientSignals` 统一构造 REST/WS headers；credential exchange 明确排除 | `client_signals_spec.rb`、`attribution_spec.rb` |

`public_surface_spec.rb` 是可执行的 surface 清单；表格新增能力时必须同步新增 wire/lifecycle
测试，不能只补 `respond_to?`。

## 不变量

1. 所有动态 resource identifier 只能经 `Sprites::Routes` 作为单个 RFC 3986 path segment
   编码；`/`、空格、`?`、`#`、`%` 不得改变路由。
2. Net::HTTP implicit retry 固定为 0。SDK 不重放语义不明确的 create、exec、kill、
   checkpoint、restore 或 service command。
3. 普通 HTTP 使用有界 keep-alive pool；每条 connection 同时只服务一个 request。
4. checkpoint、restore、service、state-watch 与 session-kill 是增量 NDJSON，不得先缓冲完整
   body。消费到 EOF、读取失败或显式 close 都必须释放 connection。
5. WebSocket 必须校验 `101`、Upgrade/Connection 与 `Sec-WebSocket-Accept`，客户端 frame
   必须 masked；非法 RSV、mask、opcode、长度、UTF-8 与 close payload 一律 fail closed。
6. `Client#close` 是本 client 的 connection scope：关闭 active direct command、HTTP stream、
   watcher、proxy、control pool 与 HTTP pool；不关闭其他 Client 或 sibling command。
7. provider/API error 优先解析为 `APIError`，保留 status、error code、rate limit 与 retry headers。
8. 所有 authenticated REST、incremental HTTP stream 与 WebSocket handshake 必须经过
   `ClientSignals`；任何模块不得自行拼 `Bearer`、`Fly-Client-*` 或 SDK `User-Agent`。

## Filesystem wire 证据

`dev-latest` 文档与当前官方 SDK 在 filesystem 的两个字段上存在漂移：文档曾把父目录参数
写成 `mkdir`，并把 delete 描述为 JSON body；当前官方 JS SDK 与真实 API 使用
`mkdirParents=true`，delete 使用 `path`、`workingDir`、`recursive`、`asRoot` query parameters。

因此 Ruby 的稳定 contract 由三层证据共同锁定：

1. `filesystem_spec.rb` 固定 Ruby SDK wire；
2. `live_api_contract_spec.rb` 对真实 provider 做 opt-in canary；
3. Gateway 的 `filesystem_sdk_contract_test.rb` 比较应用 raw streaming adapter 与本 SDK
   的归一化请求，禁止应用再次维护另一份字段清单。

## HTTP exec 的协议限制

官方 HTTP exec wire format 只有一个 type byte，没有 payload length，因而依赖 HTTP transport
交付的 chunk 边界。Ruby 实现直接在原生 `Net::HTTP#request` block 内消费 `read_body`，不会
经过 `IO.pipe` 重新分块；真实 Ruby 4 chunked server 测试证明标准路径可工作。

中间代理仍可能合并 chunk，而协议无法无歧义地从 stdout/stderr 任意字节中恢复边界。
实现会拒绝未知 frame、非法 exit 长度、缺失 exit 与 buffer overflow，但无法证明所有合并
情形。大输出、二进制输出和高可靠命令必须使用 WebSocket `Cmd`；HTTP exec 只作为明确的
非 WebSocket fallback。

## 验证命令

```bash
rvm ruby-4.0.6 do bundle exec rspec

SPRITES_LIVE_API=1 \
SPRITES_LIVE_TOKEN=... \
SPRITES_LIVE_NAME=... \
rvm ruby-4.0.6 do bundle exec rspec spec/sprites/live_api_contract_spec.rb
```

`real_http_integration_spec.rb` 必须使用原生 Net::HTTP；测试会临时卸载 WebMock adapter，
验证真实 keep-alive 并行、HTTP chunk 与 incremental NDJSON。
