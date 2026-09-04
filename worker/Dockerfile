# The GoHighLevel integration worker. Build context is ./worker.
#
# Debian (slim), not Alpine. sharp ships prebuilt native binaries per
# platform as optional dependencies, and musl is a separate one from
# glibc -- so an image built on Alpine needs @img/sharp-linuxmusl-x64
# while the lockfile written on a glibc machine reaches for the glibc
# build. That mismatch produces an image that installs cleanly and then
# cannot load sharp at runtime. Matching the base to the platform the
# lockfile and the tests were made on removes the whole question.
FROM node:22-slim

WORKDIR /app
ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# The image is not usable if its native dependency will not load, and
# finding that out from a container in production is finding it out too
# late. This is the same failure mode as an earlier web image that copied
# only two of its four modules: it passed every test and broke only in the
# registry. Assert here, where it stops the publish.
RUN node -e "const s=require('sharp'); s({create:{width:8,height:8,channels:3,background:'#000'}}).jpeg().toBuffer().then(()=>console.log('sharp ok'))"

COPY src ./src
# The operator entry points. The nightly listing sweep is run as
#   docker compose run --rm worker node tools/check-listings.js
# so they have to be in the image, not just in the repository.
COPY tools ./tools

USER node

EXPOSE 3001
CMD ["node", "src/index.js"]
