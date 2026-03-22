FROM node:20-bullseye-slim
WORKDIR /app
COPY server/package*.json ./
RUN npm install --omit=dev
COPY server/ ./
RUN mkdir -p /app/certs
EXPOSE 8443
CMD ["node", "index.js"]
