# omo-switcher 服务端镜像。仅打包 server/ 下的代码与生产依赖。
FROM node:20-alpine

# 时区/健康检查用到 wget（alpine 自带 busybox wget，无需额外安装）。
WORKDIR /app

# 先装依赖（利用层缓存）：只复制 manifest。
COPY package.json ./
# 没有 lockfile 时 npm install 即可；--omit=dev 只装生产依赖。
RUN npm install --omit=dev --no-audit --no-fund

# 复制源码。
COPY src ./src

# 容器内默认绑定 0.0.0.0，否则宿主机无法访问。
ENV OMO_SWITCHER_HOST=0.0.0.0 \
    OMO_SWITCHER_PORT=7600 \
    NODE_ENV=production

EXPOSE 7600

# 简单健康检查：打 /api/health。
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${OMO_SWITCHER_PORT}/api/health" >/dev/null 2>&1 || exit 1

CMD ["node", "src/index.js"]
