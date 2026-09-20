#############################################################################
#  clash (mihomo) + nginx + zashboard 多阶段构建
#  - nginx(源镜像) = iflyelf/nginx:latest : 提供已编译的 nginx 及 Lua/WAF 产物
#  - down(下载阶段) = iflyelf/ubuntu:latest : 已预装 curl/jq/wget/unzip/tar/xz,
#      无需再装庞大依赖, 仅用于按架构下载 mihomo 与 zashboard 前端产物
#  - runtime(运行阶段) = iflyelf/ubuntu:lite : 仅拷贝产物 + 装 supervisor 与
#      nginx 运行所需的共享库, 镜像更小
#############################################################################

# 指定 nginx 源镜像
ARG BUILD_NGINX_IMAGE=iflyelf/nginx:latest

# ========================= nginx 产物来源 =========================
FROM ${BUILD_NGINX_IMAGE} AS nginx


####################################################################
#                 下载阶段 (down) = ubuntu:latest                   #
####################################################################
FROM iflyelf/ubuntu:latest AS down

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf"

# buildx 自动注入的目标架构
ARG TARGETARCH
ARG TARGETVARIANT

# 时区/语言
ARG TZ=Asia/Shanghai
ENV TZ=$TZ
ARG LANG=C.UTF-8
ENV LANG=$LANG

# ubuntu:latest 已含 curl/jq/wget/unzip/tar/xz-utils/git, 无需再装依赖。
# 下载 mihomo(clash) 内核与 zashboard 前端
RUN set -eux \
    && case "${TARGETARCH}" in \
        amd64) ARCH_PATTERN="linux-amd64-compatible-alpha" ;; \
        arm64) ARCH_PATTERN="linux-arm64-alpha" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && export CLASH_DOWN=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases | jq -r .[].assets[].browser_download_url | grep -i Alpha | grep -i gz | grep -i ${ARCH_PATTERN} | head -n 1) \
    && wget --no-check-certificate -O /tmp/clash.gz $CLASH_DOWN \
    && cd /tmp && gzip -d clash.gz \
    && wget --no-check-certificate -O /tmp/dist.zip https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip \
    && cd /tmp && unzip dist.zip


####################################################################
#              运行阶段 (runtime) = ubuntu:lite                     #
####################################################################
FROM iflyelf/ubuntu:lite

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf" \
      org.opencontainers.image.description="clash(mihomo) + nginx + zashboard, runtime on ubuntu:lite"

# buildx 自动注入的目标架构
ARG TARGETARCH
ARG TARGETVARIANT

# 时区设置
ARG TZ=Asia/Shanghai
ENV TZ=$TZ
# 语言设置
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG

# 环境设置
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=$DEBIAN_FRONTEND

# 镜像变量
ARG DOCKER_IMAGE=iflyelf/clash
ENV DOCKER_IMAGE=$DOCKER_IMAGE

# 工作目录 / nginx 环境变量
ARG NGINX_DIR=/data/nginx
ENV NGINX_DIR=$NGINX_DIR
# nginx sbin 进 PATH; LuaJIT/coraza 共享库进库路径
ENV PATH=${NGINX_DIR}/sbin:/usr/local/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/lib

# ***** 运行阶段按需依赖 *****
# supervisor  -> 进程管理(同时守护 nginx 与 clash)
# iptables    -> clash tun/透明代理场景可能需要
# nginx 运行所需共享库(与 iflyelf/nginx runtime 一致):
#   libpcre2-8-0(正则) zlib1g(gzip) libgd3(image_filter)
#   libxml2-16(coraza WAF) libaio1t64(file-aio) ca-certificates(TLS 根证书)
ARG RUNTIME_DEPS="\
    supervisor \
    iptables \
    libpcre2-8-0 \
    zlib1g \
    libgd3 \
    libxml2-16 \
    libaio1t64 \
    ca-certificates"
ENV RUNTIME_DEPS=$RUNTIME_DEPS

# ***** 安装运行依赖 *****
RUN set -eux && \
   # 更新系统软件
   DEBIAN_FRONTEND=noninteractive apt-get update -qqy && apt-get upgrade -qqy && \
   # 安装运行依赖包
   DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends $RUNTIME_DEPS --option=Dpkg::Options::=--force-confdef && \
   # 验证依赖包是否真正安装成功(逐个检查 dpkg 状态, 缺失则构建失败)
   for pkg in $RUNTIME_DEPS; do \
       if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then \
           echo "ERROR: 运行依赖未成功安装: $pkg" >&2 && exit 1; \
       fi; \
   done && \
   echo "运行依赖验证通过" && \
   DEBIAN_FRONTEND=noninteractive apt-get -qqy autoremove --purge && \
   DEBIAN_FRONTEND=noninteractive apt-get -qqy autoclean && \
   rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* && \
   # 更新时区
   ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && \
   echo ${TZ} > /etc/timezone

# 拷贝 clash 内核与 zashboard 前端
COPY --from=down /tmp/clash /usr/bin/clash
COPY --from=down /tmp/dist /www
COPY ["./conf/clash/config.yaml", "/root/.config/clash/"]

# 拷贝 nginx 编译产物
COPY --from=nginx /usr/local/lib /usr/local/lib
COPY --from=nginx /usr/local/share/lua /usr/local/share/lua
COPY --from=nginx /data/nginx /data/nginx

# 拷贝入口脚本与配置
COPY ["./docker-entrypoint.sh", "/usr/bin/"]
COPY ["./conf/nginx/ssl", "/ssl"]
COPY ["./conf/nginx/vhost/default.conf", "/data/nginx/conf/vhost/default.conf"]
COPY ["./conf/supervisor", "/etc/supervisor"]

# ***** 初始化: 用户/权限/动态库/自检 *****
RUN set -eux && \
    # 注册 libcoraza.so / libluajit 到动态链接库缓存
    ldconfig && \
    # 创建 nginx 用户和用户组
    addgroup --system --quiet nginx && \
    adduser --quiet --system --disabled-login --ingroup nginx --home /data/nginx --no-create-home nginx && \
    # 授权可执行文件
    chmod a+x /usr/bin/docker-entrypoint.sh /usr/bin/clash && \
    chown --quiet -R nginx:nginx /www && chmod -R 775 /www && \
    # 日志转发到 docker 日志收集器
    ln -sf /dev/stdout /data/nginx/logs/access.log && \
    ln -sf /dev/stderr /data/nginx/logs/error.log && \
    # 软链 nginx 到系统 PATH
    ln -sf ${NGINX_DIR}/sbin/* /usr/sbin/ && \
    # smoke test: 打印编译参数并校验配置
    nginx -V && \
    nginx -t && \
    rm -rf /var/lib/apt/lists/* /tmp/*

# ***** 工作目录 *****
WORKDIR /root

# ***** 监听端口(clash 混合/http/socks + web) *****
EXPOSE 80 443 7890 7891 7892

# ***** 入口(tini 作为 init, 优雅处理信号) *****
ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]

# 自动检测服务是否可用
HEALTHCHECK --interval=30s --timeout=3s CMD curl --fail http://localhost/ || exit 1
