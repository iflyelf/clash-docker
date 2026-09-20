# clash-docker

clash（[mihomo](https://github.com/MetaCubeX/mihomo) 内核）+ nginx + [zashboard](https://github.com/Zephyruso/zashboard)
面板一体化镜像，用 supervisor 同时守护 clash 与 nginx。采用多阶段构建，运行镜像更小。

支持 `linux/amd64` 与 `linux/arm64` 多架构，标签为 `latest`。

## 多阶段构建

| 阶段 | 基础镜像 | 作用 |
| --- | --- | --- |
| nginx | `iflyelf/nginx:latest` | 提供已编译的 nginx 及 Lua / WAF 产物 |
| down | `iflyelf/ubuntu:latest` | 已预装 curl / jq / wget / unzip / tar / xz，仅用于按架构下载 mihomo 内核与 zashboard 前端，无需再装依赖 |
| runtime | `iflyelf/ubuntu:lite` | 仅拷贝产物 + 安装 supervisor 与 nginx 运行所需的共享库，镜像更小 |

运行阶段按需安装：`supervisor`（进程守护）、`iptables`（tun/透明代理场景）、
以及 nginx 运行库 `libpcre2-8-0`、`zlib1g`、`libgd3`、`libxml2-16`、`libaio1t64`、`ca-certificates`。

运行阶段环境变量：`PATH` 追加 `${NGINX_DIR}/sbin`，`LD_LIBRARY_PATH=/usr/local/lib`（加载 LuaJIT / libcoraza 共享库），入口使用 tini。

## 镜像获取

```bash
# Docker Hub（国外）
docker pull iflyelf/clash:latest

# 华为云 SWR（国内推荐）
docker pull swr.cn-east-3.myhuaweicloud.com/iflyelf/clash:latest
```

## 运行

推荐使用仓库内的 `docker-compose.yml`：

```bash
docker compose up -d
```

或手动运行（需挂载 clash 配置）：

```bash
docker run -d --name clash \
  --privileged \
  --device /dev/net/tun \
  -p 7890:7890 -p 7891:7891 -p 7892:7892 \
  -v $(pwd)/conf/clash/config.yaml:/root/.config/clash/config.yaml \
  iflyelf/clash:latest
```

## 内置组件

- clash 内核：mihomo（Alpha 版，按架构自动下载最新）
- 面板：zashboard（构建时下载最新 release）
- Web/代理：nginx（含 Lua + Coraza WAF + HTTP/3，来自 iflyelf/nginx）
- 进程守护：supervisor（同时管理 nginx 与 clash）
- 端口：`7890`（混合代理）、`7891`（HTTP）、`7892`（SOCKS）、`80`/`443`（Web）

## 自动构建

以下情况会触发 [GitHub Actions](./.github/workflows/docker-publish.yml) 构建并推送到 Docker Hub 与华为云 SWR：

- 推送 `Dockerfile`、`conf/**`、`docker-entrypoint.sh` 或工作流文件变更
- 手动触发（workflow_dispatch）
- Star 仓库
- 定时构建：**中国时间每天早 5 点**（UTC 21:00）

同一分支仅保留最新一次构建（`concurrency` + `cancel-in-progress`），避免多架构构建并发堆积。
定时构建会自动获取最新的 mihomo 内核与 zashboard 面板。

### 所需 Secrets

| Secret | 说明 |
| --- | --- |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Docker Hub 凭据 |
| `SWR_USERNAME` / `SWR_PASSWORD` | 华为云 SWR 登录凭据（`区域@AK` / 登录密钥） |
| `SWR_AK` / `SWR_SK` | 华为云账号 AK/SK，用于将 SWR 仓库设为公开（可选） |
