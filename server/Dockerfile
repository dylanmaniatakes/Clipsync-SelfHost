FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

ENV NODE_ENV=production
ENV CLIPSYNC_BIND=0.0.0.0
ENV CLIPSYNC_PORT=8787
ENV CLIPSYNC_DATA_DIR=/app/data

RUN mkdir -p /app/data

EXPOSE 8787

CMD ["node", "./src/server.js"]
