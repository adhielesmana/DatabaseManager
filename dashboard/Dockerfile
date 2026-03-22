FROM node:20-bullseye-slim
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends default-mysql-client \
  && rm -rf /var/lib/apt/lists/*
COPY server/package*.json ./
RUN npm install --omit=dev
COPY server/ ./
RUN mkdir -p /app/certs
EXPOSE 8443
CMD ["node", "index.js"]
