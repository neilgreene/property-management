# The demo web tier. Build context is ./web.
FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

# Copy the manifest first so the dependency layer is cached independently of
# the source. npm ci -- not npm install -- so the build is reproducible and
# fails loudly if the lockfile and manifest disagree.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Every module server.js requires, named explicitly. An earlier version of
# this line listed only server.js and auth.js, which meant adding media.js
# and nlq.js produced an image that crashed on its first require -- the sort
# of break that passes every test and fails only in the registry.
COPY server.js auth.js media.js nlq.js ./
COPY public ./public

# Runs unprivileged. node:alpine ships a `node` user for exactly this.
USER node

EXPOSE 3000
CMD ["node", "server.js"]
