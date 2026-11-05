# Infra wrapper around oxytrip-frontend/Dockerfile.local — pins the native SWC
# binary so `next build` does not download over the network inside Docker.
# NEXT_PUBLIC_BOT_WEBHOOK_SECRET is no longer a build arg (review 6 Nov 2026): a
# NEXT_PUBLIC_ value is baked into the image, and the site reads only the runtime
# BOT_WEBHOOK_SECRET now.
FROM node:20-bookworm-slim AS builder
WORKDIR /app

COPY package*.json ./
RUN npm install --include=dev --include=optional \
    && npm install @next/swc-linux-x64-gnu --no-save

COPY . .

ARG NEXT_PUBLIC_BASE_URL=http://localhost:3000
ARG NEXT_PUBLIC_CMS_PROVIDER=payload
ARG NEXT_PUBLIC_BOT_URL
ARG NEXT_IMAGE_UNOPTIMIZED=true

ENV NEXT_PUBLIC_BASE_URL=$NEXT_PUBLIC_BASE_URL
ENV NEXT_PUBLIC_CMS_PROVIDER=$NEXT_PUBLIC_CMS_PROVIDER
ENV NEXT_PUBLIC_BOT_URL=$NEXT_PUBLIC_BOT_URL
ENV NEXT_IMAGE_UNOPTIMIZED=$NEXT_IMAGE_UNOPTIMIZED
ENV NEXT_TELEMETRY_DISABLED=1

RUN npm run build

FROM node:20-bookworm-slim AS runner
ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

WORKDIR /app
COPY --from=builder /app/public ./public
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

EXPOSE 3000
CMD ["node", "server.js"]
