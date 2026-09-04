# The demo web tier. Build context is ./web.
#
# Debian (slim), not Alpine, for the same reason the worker is: sharp ships
# a separate prebuilt binary per libc, and an image built on musl with a
# lockfile written on glibc installs cleanly and then cannot load it. That
# cost a deploy cycle once already.
FROM node:22-slim

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
# The image is not usable if its native dependency will not load, and
# finding that out from a running container is finding it out too late.
RUN node -e "const s=require('sharp'); s({create:{width:8,height:8,channels:3,background:'#000'}}).jpeg().toBuffer().then(()=>console.log('sharp ok'))"

COPY server.js auth.js media.js nlq.js images.js ./
COPY public ./public

# Stamped at build time so the running container can say which build it is.
# The build context is ./web, so the repository's VERSION file cannot simply
# be copied in -- CI reads it and passes it here. Anything built without
# these says "dev", which is honest: a wrong version number is worse than
# none, being the thing somebody trusts while chasing the wrong bug.
ARG SDI_VERSION=dev
ARG SDI_COMMIT=
ENV SDI_VERSION=$SDI_VERSION
ENV SDI_COMMIT=$SDI_COMMIT

# Runs unprivileged. node:alpine ships a `node` user for exactly this.
USER node

EXPOSE 3000
CMD ["node", "server.js"]
