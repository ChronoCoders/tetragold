FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

COPY tsconfig.json ./
COPY src ./src

RUN npm install --no-save tsx

# ENTRYPOINT chosen by the service (keeper, exporter, or api) in docker-compose.
ENTRYPOINT ["npx", "tsx"]
CMD ["src/exporter.ts"]
