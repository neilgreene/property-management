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

# Every .js file at the root of ./web, by glob rather than by name.
#
# This line used to name each module explicitly, and it went stale twice --
# once when media.js and nlq.js were added, and again when share.js was.
# Both times the image built, pushed, passed every test, and then crashed on
# its first require in front of somebody. A list that must be edited in
# lockstep with an import is a list that will be forgotten, and the failure
# lands as far from the mistake as it is possible to get.
#
# The glob picks up exactly the server's modules: tests live in ./test and
# browser code in ./public, neither of which is at this level.
# The image is not usable if its native dependency will not load, and
# finding that out from a running container is finding it out too late.
RUN node -e "const s=require('sharp'); s({create:{width:8,height:8,channels:3,background:'#000'}}).jpeg().toBuffer().then(()=>console.log('sharp ok'))"

COPY *.js ./
COPY public ./public

# And a belt to go with the braces: resolve every local module server.js
# imports, at build time. A missing file then fails the BUILD, in CI,
# rather than the first request against a container already deployed.
RUN node -e "const fs=require('fs');const src=fs.readFileSync('/app/server.js','utf8');const mods=[...src.matchAll(/require\(.(\.\/[^']+)./g)].map(m=>m[1]);for (const m of mods) require.resolve('/app/'+m.slice(2));console.log('server modules resolve: '+mods.join(' '))"

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
