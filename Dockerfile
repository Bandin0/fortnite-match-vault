# ---- build the C# replay reader (handles encrypted + current-version replays) ----
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY replay2json/ ./
RUN dotnet publish -c Release -r linux-x64 --self-contained true -p:PublishSingleFile=true -o /out

# ---- runtime: node web app + the reader binary ----
FROM node:22-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY app/package.json ./
RUN npm install --omit=dev
COPY app/ ./
COPY --from=build /out/replay2json /usr/local/bin/replay2json
ENV PORT=8090 DATA_DIR=/data
EXPOSE 8090
CMD ["node", "server.js"]