# syntax=docker/dockerfile:1.7

# -- build --------------------------------------------------------------------
FROM node:20-alpine AS build
WORKDIR /app

COPY ui/package.json ui/package-lock.json ./
RUN npm install --no-audit --no-fund

COPY ui/. ./
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# -- runtime ------------------------------------------------------------------
FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=build /app/.next        ./.next
COPY --from=build /app/public       ./public
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./package.json

USER node
EXPOSE 3000
CMD ["sh", "-c", "npx next start -H 0.0.0.0 -p ${PORT:-3000}"]
