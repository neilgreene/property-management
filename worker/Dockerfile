# The GoHighLevel integration worker. Build context is ./worker.
FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src
# The operator entry points. The nightly listing sweep is run as
#   docker compose run --rm worker node tools/check-listings.js
# so they have to be in the image, not just in the repository.
COPY tools ./tools

USER node

EXPOSE 3001
CMD ["node", "src/index.js"]
