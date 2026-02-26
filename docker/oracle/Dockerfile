# Fake oracle for Zephyr DEVNET - provides signed, controllable price data

FROM node:22-alpine

WORKDIR /app

COPY tools/fake-oracle/server.js tools/fake-oracle/oracle_private.pem tools/fake-oracle/oracle_public.pem ./

ENV ORACLE_PORT=5555

EXPOSE 5555

HEALTHCHECK --interval=5s --timeout=3s --retries=5 --start-period=3s \
  CMD wget -qO- http://127.0.0.1:5555/status || exit 1

CMD ["node", "server.js"]
