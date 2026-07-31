# Ruby 4、Fiber 与 Puma 并发设计

## 结论

SDK 不安装、不启动也不拥有 Fiber scheduler，不增加 `async` runtime dependency；公共 API
保持同步且 scheduler-compatible。trunkim 当前 Puma 部署继续使用 worker process × thread
pool 承担 request 并发，SDK 在一个 process 内用有界 connection pool 和隔离的 command
transport 提供 I/O 并行。

这是职责边界，而不是拒绝 Fiber：若宿主在当前 thread 安装 scheduler，并在 non-blocking
Fiber 内调用 SDK，Ruby 的 socket、IO、Mutex、ConditionVariable、Queue 与 Thread#join 会
经 scheduler hooks 协作等待。SDK 不应替宿主选择 event loop，也不能在 library 内改变 Puma
thread 的全局执行模型。

## 官方依据

- Ruby Fiber 文档：<https://ruby-doc.org/3.4/fiber_md.html>
  - scheduler 只安装在当前 thread；
  - hooks 只在 non-blocking execution context 生效；
  - Ruby 定义 interface，但典型 event loop 由 Async 等实现；
  - IO、Mutex、ConditionVariable、Queue/SizedQueue、Thread#join 支持 scheduler。
- Puma 8 文档：<https://puma.io/puma/>
  - 每个 request 由 thread 服务；cluster mode 的 thread 数按 worker 计算；
  - MRI 在外部 I/O 等待期间可让其他 Puma threads 继续执行。
- Puma 8 DSL：<https://puma.io/puma/Puma/DSL.html>
  - `fiber_per_request` 提供干净的 Fiber-local/Fiber storage scope，不等于安装 scheduler；
  - `max_io_threads` 允许显式标记的 I/O-bound request 超过普通 thread 上限。
- Puma 8 upgrade：<https://puma.io/puma/file.8.0-Upgrade.html>
  - `env["puma.mark_as_io_bound"]` 是 framework/受控 request 边界，官方不建议应用无差别标记。

## SDK concurrency model

| 路径 | 并发/背压 | 生命周期 |
|---|---|---|
| 普通 HTTP | 每 Client 默认最多 8 条 lazy keep-alive connection；connection checkout 独占 | `Client#close`；fork 后按 PID 丢弃 inherited idle socket |
| direct Cmd | 每条 active command 独立 WebSocket 与 I/O thread | command 完成/断开或 `Client#close` |
| control Cmd | 每 Sprite bounded pool，connection 在 `op.complete` 后才可复用 | pool checkin/close；remote EOF 关闭 Queue 并唤醒 waiter |
| HTTP NDJSON stream | 独占 Net::HTTP connection；producer thread + `IO.pipe` 提供 OS 有界背压 | EOF/error/stream close/Client close |
| WebSocket watcher | 调用方 thread/Fiber 直接读取，不创建 background reader | EOF/error/watcher close/Client close |
| proxy | listener、每 tunnel handler 与一个反向 copy thread | session close 会关闭 active local/remote I/O 并 join owned threads |

## Puma 部署

当前 trunkim 生产默认 `workers=2`、每 worker `threads=10`。理论 request 并发是 20，但每个
process 有独立 Ruby heap、Client 与 socket pool，不能把 Client 或 descriptor 当作跨 worker
共享对象。`preload_app!` 后应在 worker 内懒创建 Client；HTTP pool 仍有 PID fence，防止误用
master 继承的 idle socket。

`PUMA_MAX_IO_THREADS` 默认保持 0。只有 controller 能准确划定“此 request 从现在起主要等待
外部 I/O”时，才调用 `request.env["puma.mark_as_io_bound"]` 并由容量测试决定额外线程数。
不要因为 SDK 是网络客户端就全局开启 `fiber_per_request`、Async 或扩大 thread pool。

并行 LLM ToolCall 必须由上层 runtime 控制每个 turn/agent 的并发上限；SDK 的 8 条 HTTP
connection 上限与每 Sprite control pool 上限是 transport safety cap，不是产品任务队列。
一条卡死 direct command 只占自己的 WebSocket/thread；断开它不会关闭 sibling command，
该不变量由 `cmd_spec.rb` 的双连接测试覆盖。

## 何时重新评估 Async

只有同时满足以下条件才考虑宿主级 scheduler：

1. profile 证明 Puma threads 大量耗在可被 scheduler 拦截的 socket I/O，而不是 LLM/job
   orchestration、数据库连接池或 CPU；
2. Rails、数据库 adapter、observability、WebSocket 和所有 provider SDK 在目标 scheduler 下
   有生产级支持；
3. 每个 Puma worker 明确安装/关闭 scheduler，并完成 timeout、cancel、fork、shutdown、
   Fiber-local state 与 Active Record connection ownership 压测；
4. 与现有 worker × thread 配置做相同资源约束下的吞吐、p95/p99、RSS、socket 与故障恢复
   对照，而不是只比较 happy-path microbenchmark。

在这些证据出现前，增加 `async` API 会形成 sync/async 双栈、双生命周期和更复杂的 Rails
上下文传播，收益不确定，故不进入 SDK。
